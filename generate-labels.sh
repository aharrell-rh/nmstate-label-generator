#!/usr/bin/env bash
# generate-labels.sh
# Converts a cluster networking YAML into the config dictionary format
# consumed by the Autoshift policy-nmstate-nncp policy (original, unmodified).
#
# Each node gets one host entry per VLAN and one for MTU, producing:
#   nmstate-host-<node>-vlan<id>    NNCP  → bond0.<id>, static IP, nodeSelector
#   nmstate-host-<node>-mtu         NNCP  → eno1 + eno2 + bond0 MTU, nodeSelector
#
# The hostname field in each host entry carries the full FQDN so the policy
# uses it directly as the kubernetes.io/hostname nodeSelector value.
#
# Usage:
#   sh generate-labels.sh <values-file.yaml> [--force]
#
# Requires: yq (mikefarah/yq v4.6+)

set -euo pipefail

# ── colour output ─────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
  RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
  BLUE='\033[0;34m'; NC='\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; BLUE=''; NC=''
fi
error()   { echo -e "${RED}ERROR:${NC} $1"    >&2; }
info()    { echo -e "${BLUE}INFO:${NC} $1"    >&2; }
success() { echo -e "${GREEN}SUCCESS:${NC} $1" >&2; }

# ── args ──────────────────────────────────────────────────────────────────────
VALUES_FILE="${1:?Usage: $0 <values-file.yaml> [--force]}"
FORCE="${2:-}"

BASENAME=$(basename "$VALUES_FILE" .yaml)
OUTPUT_FILE="${BASENAME}-autoshift-nmstate-config.yaml"
BASE_IFACE="bond0"

# ── overwrite guard ───────────────────────────────────────────────────────────
if [[ -f "$OUTPUT_FILE" && "$FORCE" != "--force" ]]; then
  if [[ -t 0 ]]; then
    echo -e "${YELLOW}WARNING:${NC} ${OUTPUT_FILE} already exists."
    read -rp "Overwrite? (y/N): " CONFIRM
    CONFIRM=$(echo "$CONFIRM" | tr '[:upper:]' '[:lower:]')
    [[ "$CONFIRM" == "y" || "$CONFIRM" == "yes" ]] || { echo -e "${RED}Aborted.${NC}"; exit 1; }
  else
    error "${OUTPUT_FILE} already exists. Use --force to overwrite."
    exit 1
  fi
fi

# ── read dimensions ───────────────────────────────────────────────────────────
DEFAULT_MTU=$(yq '.mtu.value' "$VALUES_FILE")
HOST_COUNT=$(yq '.hostnames | length' "$VALUES_FILE")
VLAN_COUNT=$(yq '.vlans | length' "$VALUES_FILE")
MTU_IFACE_COUNT=$(yq '.mtu.interfaces | length' "$VALUES_FILE")

info "Detected ${HOST_COUNT} host(s), ${VLAN_COUNT} VLAN(s), MTU ${DEFAULT_MTU}"

# ── validation ────────────────────────────────────────────────────────────────
if [[ "$VLAN_COUNT" -lt 1 ]]; then
  error "At least 1 VLAN is required."
  exit 1
fi

DUPLICATES=$(yq '.vlans[].ips[]' "$VALUES_FILE" | sort | uniq -d)
if [[ -n "$DUPLICATES" ]]; then
  error "Duplicate IP addresses detected:"
  echo "$DUPLICATES" >&2
  exit 1
fi

for ((v=0; v<VLAN_COUNT; v++)); do
  IP_COUNT=$(yq ".vlans[$v].ips | length" "$VALUES_FILE")
  VLAN_ID=$(yq ".vlans[$v].id" "$VALUES_FILE")
  if [[ "$IP_COUNT" -ne "$HOST_COUNT" ]]; then
    error "VLAN ${VLAN_ID}: has ${IP_COUNT} IP(s) but ${HOST_COUNT} host(s) — must match."
    exit 1
  fi
  VLAN_PREFIX=$(yq ".vlans[$v].prefixLength" "$VALUES_FILE")
  if [[ -z "$VLAN_PREFIX" || "$VLAN_PREFIX" == "null" ]]; then
    error "VLAN ${VLAN_ID} is missing prefixLength."
    exit 1
  fi
done

success "Validation passed."

# ── generate output ───────────────────────────────────────────────────────────
TMPFILE=$(mktemp)

# ─────────────────────────────────────────────────────────────────────────────
# networking.interfaces  (topology — tells the policy how to render each iface)
#
# VLAN entries:  type / name / base / id / ipv4 mode
# MTU entries:   type / name / mtu / mode
#
# These are ALL per-host (every key appears in at least one host block), so
# the policy will skip them in the cluster-wide loop and only render them
# as part of the per-host NNCPs.
# ─────────────────────────────────────────────────────────────────────────────
cat >> "$TMPFILE" <<EOF
networking:
  interfaces:
EOF

# VLAN topology entries
for ((v=0; v<VLAN_COUNT; v++)); do
  VLAN_ID=$(yq ".vlans[$v].id" "$VALUES_FILE")
  IFACE_KEY="${BASE_IFACE}-vlan${VLAN_ID}"

  cat >> "$TMPFILE" <<EOF
    ${IFACE_KEY}:
      name: ${BASE_IFACE}.${VLAN_ID}
      type: vlan
      state: up
      ipv4: static
      ipv6: disabled
      base: ${BASE_IFACE}
      id: ${VLAN_ID}
EOF
done

# MTU interface topology entries
for ((i=0; i<MTU_IFACE_COUNT; i++)); do
  IF_NAME=$(yq ".mtu.interfaces[$i].name" "$VALUES_FILE")
  IF_TYPE=$(yq ".mtu.interfaces[$i].type" "$VALUES_FILE")

  if [[ "$IF_TYPE" == "bond" ]]; then
    cat >> "$TMPFILE" <<EOF
    ${IF_NAME}:
      name: ${IF_NAME}
      type: ${IF_TYPE}
      state: up
      mtu: ${DEFAULT_MTU}
      ipv4: disabled
      ipv6: disabled
      mode: active-backup
EOF
  else
    cat >> "$TMPFILE" <<EOF
    ${IF_NAME}:
      name: ${IF_NAME}
      type: ${IF_TYPE}
      state: up
      mtu: ${DEFAULT_MTU}
EOF
  fi
done

# ─────────────────────────────────────────────────────────────────────────────
# hosts
#
# One entry per VLAN per node  → policy renders nmstate-host-<key>
# One MTU entry per node       → policy renders nmstate-host-<key>
#
# Key format:
#   <short>-vlan<id>   e.g. node1-vlan100
#   <short>-mtu        e.g. node1-mtu
#
# Each entry carries hostname: <full-fqdn> so the policy uses it directly
# as the kubernetes.io/hostname nodeSelector — no clusterDomain lookup needed.
# ─────────────────────────────────────────────────────────────────────────────
cat >> "$TMPFILE" <<EOF

hosts:
EOF

for ((h=0; h<HOST_COUNT; h++)); do
  HOSTNAME=$(yq ".hostnames[$h]" "$VALUES_FILE")
  SHORT=$(echo "$HOSTNAME" | cut -d. -f1)

  # One host entry per VLAN
  for ((v=0; v<VLAN_COUNT; v++)); do
    VLAN_ID=$(yq ".vlans[$v].id" "$VALUES_FILE")
    VLAN_PREFIX=$(yq ".vlans[$v].prefixLength" "$VALUES_FILE")
    IP=$(yq ".vlans[$v].ips[$h]" "$VALUES_FILE")
    IFACE_KEY="${BASE_IFACE}-vlan${VLAN_ID}"
    HOST_KEY="${SHORT}-vlan${VLAN_ID}"

    cat >> "$TMPFILE" <<EOF
  ${HOST_KEY}:
    hostname: ${HOSTNAME}
    networking:
      interfaces:
        ${IFACE_KEY}:
          ipv4:
            addresses:
              - ip: ${IP}
                prefixLength: ${VLAN_PREFIX}
EOF
  done

  # One MTU host entry per node — lists all MTU interfaces
  HOST_KEY="${SHORT}-mtu"

  cat >> "$TMPFILE" <<EOF
  ${HOST_KEY}:
    hostname: ${HOSTNAME}
    networking:
      interfaces:
EOF

  for ((i=0; i<MTU_IFACE_COUNT; i++)); do
    IF_NAME=$(yq ".mtu.interfaces[$i].name" "$VALUES_FILE")

    cat >> "$TMPFILE" <<EOF
        ${IF_NAME}:
          {}
EOF
  done

done

mv "$TMPFILE" "$OUTPUT_FILE"

# ── summary ───────────────────────────────────────────────────────────────────
VLAN_NNCPS=$(( HOST_COUNT * VLAN_COUNT ))
MTU_NNCPS=${HOST_COUNT}
TOTAL=$(( VLAN_NNCPS + MTU_NNCPS ))
success "Written to ${OUTPUT_FILE}"
success "Will render: ${VLAN_NNCPS} VLAN NNCP(s) + ${MTU_NNCPS} MTU NNCP(s) = ${TOTAL} total"