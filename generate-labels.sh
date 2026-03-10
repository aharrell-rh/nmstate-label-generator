#!/usr/bin/env bash
set -euo pipefail

if [[ -t 1 ]]; then
  RED='\033[0;31m'
  GREEN='\033[0;32m'
  YELLOW='\033[1;33m'
  BLUE='\033[0;34m'
  NC='\033[0m'
else
  RED=''
  GREEN=''
  YELLOW=''
  BLUE=''
  NC=''
fi

error()   { echo -e "${RED}ERROR:${NC} $1"; }
info()    { echo -e "${BLUE}INFO:${NC} $1"; }
success() { echo -e "${GREEN}SUCCESS:${NC} $1"; }

VALUES_FILE="${1:?Provide values.yaml}"
FORCE="${2:-}"

BASENAME=$(basename "$VALUES_FILE" .yaml)
OUTPUT_FILE="${BASENAME}-autoshift-nmstate-labels.yaml"

DEFAULT_MTU=$(yq '.mtu.value // 9000' "$VALUES_FILE")
BOND_NAME=$(yq -r '.mtu.bond.name // "bond0"' "$VALUES_FILE")
BOND_MODE=$(yq -r '.mtu.bond.mode // "active-backup"' "$VALUES_FILE")

HOST_COUNT=$(yq '.hosts | length' "$VALUES_FILE")
VLAN_COUNT=$(yq '.vlans | length' "$VALUES_FILE")

if [[ -f "$OUTPUT_FILE" && "$FORCE" != "--force" ]]; then
  echo -e "${YELLOW}WARNING:${NC} ${OUTPUT_FILE} already exists."
  read -rp "Overwrite? (y/N): " CONFIRM
  CONFIRM=$(echo "$CONFIRM" | tr '[:upper:]' '[:lower:]')
  if [[ "$CONFIRM" != "y" && "$CONFIRM" != "yes" ]]; then
    echo -e "${RED}Aborted.${NC}"
    exit 1
  fi
fi

: > "$OUTPUT_FILE"

info "Validating input file..."

# Check for duplicate IPs across all VLANs
ALL_IPS=$(yq -r '.vlans[].ips[]' "$VALUES_FILE")
DUPLICATES=$(echo "$ALL_IPS" | sort | uniq -d)
if [[ -n "$DUPLICATES" ]]; then
  error "Duplicate IPs detected:"
  echo "$DUPLICATES"
  exit 1
fi

# Check each VLAN has an IP for every host
for ((v=0; v<VLAN_COUNT; v++)); do
  VLAN_ID=$(yq ".vlans[$v].id" "$VALUES_FILE")
  IP_COUNT=$(yq ".vlans[$v].ips | length" "$VALUES_FILE")
  if [[ "$IP_COUNT" -ne "$HOST_COUNT" ]]; then
    error "VLAN ${VLAN_ID} has ${IP_COUNT} IPs but ${HOST_COUNT} hosts."
    exit 1
  fi
done

success "Validation passed."

NNCP_COUNT=0

# ============================================================
# VLAN NNCP labels
# ============================================================
info "Generating VLAN NNCP labels..."

for ((h=0; h<HOST_COUNT; h++)); do

  HOSTNAME=$(yq -r ".hosts[$h].hostname" "$VALUES_FILE")
  HOST_SHORT=$(echo "$HOSTNAME" | cut -d'.' -f1)

  for ((v=0; v<VLAN_COUNT; v++)); do

    VLAN_ID=$(yq ".vlans[$v].id" "$VALUES_FILE")
    PREFIX=$(yq ".vlans[$v].prefixLength" "$VALUES_FILE")
    IP=$(yq -r ".vlans[$v].ips[$h]" "$VALUES_FILE")

    echo "nmstate-host-${HOST_SHORT}-vlan${VLAN_ID}-hostname: ${HOSTNAME}" >> "$OUTPUT_FILE"
    echo "nmstate-host-${HOST_SHORT}-vlan${VLAN_ID}-vlan-1: ${BOND_NAME}.${VLAN_ID}" >> "$OUTPUT_FILE"
    echo "nmstate-host-${HOST_SHORT}-vlan${VLAN_ID}-vlan-1-base: ${BOND_NAME}" >> "$OUTPUT_FILE"
    echo "nmstate-host-${HOST_SHORT}-vlan${VLAN_ID}-vlan-1-id: \"${VLAN_ID}\"" >> "$OUTPUT_FILE"
    echo "nmstate-host-${HOST_SHORT}-vlan${VLAN_ID}-vlan-1-ipv4: static" >> "$OUTPUT_FILE"
    echo "nmstate-host-${HOST_SHORT}-vlan${VLAN_ID}-vlan-1-ipv4-address-1: ${IP}" >> "$OUTPUT_FILE"
    echo "nmstate-host-${HOST_SHORT}-vlan${VLAN_ID}-vlan-1-ipv4-address-1-cidr: \"${PREFIX}\"" >> "$OUTPUT_FILE"

    NNCP_COUNT=$((NNCP_COUNT+1))
  done

done

# ============================================================
# MTU NNCP labels
# ============================================================
info "Generating MTU NNCP labels..."

for ((h=0; h<HOST_COUNT; h++)); do

  HOSTNAME=$(yq -r ".hosts[$h].hostname" "$VALUES_FILE")
  HOST_SHORT=$(echo "$HOSTNAME" | cut -d'.' -f1)
  IFACE_COUNT=$(yq ".hosts[$h].interfaces | length" "$VALUES_FILE")

  echo "nmstate-host-${HOST_SHORT}-mtu${DEFAULT_MTU}-hostname: ${HOSTNAME}" >> "$OUTPUT_FILE"

  # Bond (shared config, one per host)
  echo "nmstate-host-${HOST_SHORT}-mtu${DEFAULT_MTU}-bond-1: ${BOND_NAME}" >> "$OUTPUT_FILE"
  echo "nmstate-host-${HOST_SHORT}-mtu${DEFAULT_MTU}-bond-1-mtu: \"${DEFAULT_MTU}\"" >> "$OUTPUT_FILE"
  echo "nmstate-host-${HOST_SHORT}-mtu${DEFAULT_MTU}-bond-1-mode: ${BOND_MODE}" >> "$OUTPUT_FILE"

  # Per-host ethernet interfaces with MAC addresses
  # MACs are stored with colons in the values file but must use dots in labels
  # so the policy's replace "." ":" conversion works correctly
  ETH_INDEX=1
  for ((i=0; i<IFACE_COUNT; i++)); do

    IF_TYPE=$(yq -r ".hosts[$h].interfaces[$i].type" "$VALUES_FILE")
    if [[ "$IF_TYPE" != "ethernet" ]]; then
      continue
    fi

    IF_NAME=$(yq -r ".hosts[$h].interfaces[$i].name" "$VALUES_FILE")
    IF_MAC=$(yq -r ".hosts[$h].interfaces[$i].mac" "$VALUES_FILE" | tr ':' '.')

    echo "nmstate-host-${HOST_SHORT}-mtu${DEFAULT_MTU}-ethernet-${ETH_INDEX}: ${IF_NAME}" >> "$OUTPUT_FILE"
    echo "nmstate-host-${HOST_SHORT}-mtu${DEFAULT_MTU}-ethernet-${ETH_INDEX}-mac: ${IF_MAC}" >> "$OUTPUT_FILE"
    echo "nmstate-host-${HOST_SHORT}-mtu${DEFAULT_MTU}-ethernet-${ETH_INDEX}-mtu: \"${DEFAULT_MTU}\"" >> "$OUTPUT_FILE"

    ETH_INDEX=$((ETH_INDEX+1))
  done

  NNCP_COUNT=$((NNCP_COUNT+1))
done

success "Created ${NNCP_COUNT} NNCP label blocks."
success "Output written to ${OUTPUT_FILE}"