#!/usr/bin/env bash
# generate-labels.sh
# Converts a cluster networking YAML into the config dictionary format
# consumed by the Autoshift rendered-config ConfigMap / policy-nmstate-nncp.
#
# Output structure:
#   networking.interfaces.<id>                        — cluster-wide (MTU, bond, VLAN topology)
#   hosts.<shortname>.networking.interfaces.<id>      — per-host VLAN IP overrides
#
# This produces:
#   • 1 cluster-wide NNCP per MTU/bond/ethernet interface
#   • 1 per-host NNCP per VLAN per node  (HOST_COUNT × VLAN_COUNT total)
#
# Usage:
#   sh generate-labels.sh <values-file.yaml> [--force]
#
# Requires: yq (mikefarah/yq v4+)

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
DEFAULT_MTU=$(yq '.mtu.value // 9000' "$VALUES_FILE")
HOST_COUNT=$(yq '.hostnames | length' "$VALUES_FILE")
VLAN_COUNT=$(yq '.vlans | length' "$VALUES_FILE")
MTU_IFACE_COUNT=$(yq '.mtu.interfaces | length' "$VALUES_FILE")

info "Detected ${HOST_COUNT} host(s), ${VLAN_COUNT} VLAN(s), MTU ${DEFAULT_MTU}"

# ── validation ────────────────────────────────────────────────────────────────
if [[ "$VLAN_COUNT" -lt 1 ]]; then
  error "At least 1 VLAN is required."
  exit 1
fi

DUPLICATES=$(yq -r '.vlans[].ips[]' "$VALUES_FILE" | sort | uniq -d)
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
# networking.interfaces  (cluster-wide)
#
# MTU / bond / ethernet:
#   Policy renders one NNCP per entry with mtu + bond config, applied to all
#   matching nodes without a per-host nodeSelector.
#
# VLAN topology entries:
#   Define type / name / base / id / ipv4-mode for each VLAN.
#   The policy merges this with the per-host IP override at render time.
# ─────────────────────────────────────────────────────────────────────────────
cat >> "$TMPFILE" <<EOF
networking:
  interfaces:
EOF

# ethernet + bond MTU interfaces
for ((i=0; i<MTU_IFACE_COUNT; i++)); do
  IF_NAME=$(yq -r ".mtu.interfaces[$i].name" "$VALUES_FILE")
  IF_TYPE=$(yq -r ".mtu.interfaces[$i].type" "$VALUES_FILE")

  cat >> "$TMPFILE" <<EOF
    ${IF_NAME}:
      name: ${IF_NAME}
      type: ${IF_TYPE}
      state: up
      mtu: ${DEFAULT_MTU}
      ipv4: disabled
      ipv6: disabled
EOF

  if [[ "$IF_TYPE" == "bond" ]]; then
    echo "      mode: active-backup" >> "$TMPFILE"
  fi
done

# VLAN topology (no IPs — IPs live in hosts.<host>.networking.interfaces)
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

# ─────────────────────────────────────────────────────────────────────────────
# hosts  (per-host)
#
# Key = short hostname (first label before the first dot).
# Policy appends $clusterDomain from the managed cluster's DNS lookup to build
# the full kubernetes.io/hostname nodeSelector value.
# Set hosts.<key>.hostname explicitly if you need to pin the exact string.
#
# Each entry only carries IP overrides; type/base/id/ipv4-mode are inherited
# from networking.interfaces above at policy render time.
# ─────────────────────────────────────────────────────────────────────────────
cat >> "$TMPFILE" <<EOF

hosts:
EOF

for ((h=0; h<HOST_COUNT; h++)); do
  HOSTNAME=$(yq -r ".hostnames[$h]" "$VALUES_FILE")
  SHORT=$(echo "$HOSTNAME" | cut -d. -f1)

  cat >> "$TMPFILE" <<EOF
  ${SHORT}:
    networking:
      interfaces:
EOF

  for ((v=0; v<VLAN_COUNT; v++)); do
    VLAN_ID=$(yq ".vlans[$v].id" "$VALUES_FILE")
    VLAN_PREFIX=$(yq ".vlans[$v].prefixLength" "$VALUES_FILE")
    IP=$(yq -r ".vlans[$v].ips[$h]" "$VALUES_FILE")
    IFACE_KEY="${BASE_IFACE}-vlan${VLAN_ID}"

    cat >> "$TMPFILE" <<EOF
        ${IFACE_KEY}:
          ipv4:
            addresses:
              - ip: ${IP}
                prefixLength: ${VLAN_PREFIX}
EOF
  done
done

mv "$TMPFILE" "$OUTPUT_FILE"

# ── summary ───────────────────────────────────────────────────────────────────
VLAN_NNCPS=$(( HOST_COUNT * VLAN_COUNT ))
success "Written to ${OUTPUT_FILE}"
success "Will render: ${MTU_IFACE_COUNT} cluster-wide interface NNCP(s) + ${VLAN_NNCPS} per-host VLAN NNCP(s)"