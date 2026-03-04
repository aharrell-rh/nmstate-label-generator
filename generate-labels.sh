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

error() { echo -e "${RED}ERROR:${NC} $1"; }
info() { echo -e "${BLUE}INFO:${NC} $1"; }
success() { echo -e "${GREEN}SUCCESS:${NC} $1"; }

VALUES_FILE="${1:?Provide values.yaml}"
FORCE="${2:-}"

BASENAME=$(basename "$VALUES_FILE" .yaml)
OUTPUT_FILE="${BASENAME}-autoshift-nmstate-labels.yaml"

BASE_IFACE="bond0"
DEFAULT_MTU=$(yq '.mtu.value // 9000' "$VALUES_FILE")

HOST_COUNT=$(yq '.hostnames | length' "$VALUES_FILE")
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

ALL_IPS=$(yq -r '.vlans[].ips[]' "$VALUES_FILE")
DUPLICATES=$(echo "$ALL_IPS" | sort | uniq -d)

if [[ -n "$DUPLICATES" ]]; then
  error "Duplicate IPs detected:"
  echo "$DUPLICATES"
  exit 1
fi

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

info "Generating VLAN NNCP labels..."

for ((h=0; h<HOST_COUNT; h++)); do

  HOSTNAME=$(yq -r ".hostnames[$h]" "$VALUES_FILE")
  HOST_SHORT=$(echo "$HOSTNAME" | cut -d'.' -f1)

  for ((v=0; v<VLAN_COUNT; v++)); do

    VLAN_ID=$(yq ".vlans[$v].id" "$VALUES_FILE")
    PREFIX=$(yq ".vlans[$v].prefixLength" "$VALUES_FILE")
    IP=$(yq -r ".vlans[$v].ips[$h]" "$VALUES_FILE")

    ID="node${HOST_SHORT}-vlan${VLAN_ID}"

    echo "nmstate-host-${HOST_SHORT}-vlan${VLAN_ID}-hostname: ${HOSTNAME}" >> "$OUTPUT_FILE"
    echo "nmstate-host-${HOST_SHORT}-vlan${VLAN_ID}-vlan-1: ${BASE_IFACE}.${VLAN_ID}" >> "$OUTPUT_FILE"
    echo "nmstate-host-${HOST_SHORT}-vlan${VLAN_ID}-vlan-1-base: ${BASE_IFACE}" >> "$OUTPUT_FILE"
    echo "nmstate-host-${HOST_SHORT}-vlan${VLAN_ID}-vlan-1-id: \"${VLAN_ID}\"" >> "$OUTPUT_FILE"
    echo "nmstate-host-${HOST_SHORT}-vlan${VLAN_ID}-vlan-1-ipv4: static" >> "$OUTPUT_FILE"
    echo "nmstate-host-${HOST_SHORT}-vlan${VLAN_ID}-vlan-1-ipv4-address-1: ${IP}" >> "$OUTPUT_FILE"
    echo "nmstate-host-${HOST_SHORT}-vlan${VLAN_ID}-vlan-1-ipv4-address-1-cidr: \"${PREFIX}\"" >> "$OUTPUT_FILE"

    NNCP_COUNT=$((NNCP_COUNT+1))
  done

done

info "Generating MTU NNCP labels..."

MTU_IFACE_COUNT=$(yq '.mtu.interfaces | length' "$VALUES_FILE")

for ((h=0; h<HOST_COUNT; h++)); do

  HOSTNAME=$(yq -r ".hostnames[$h]" "$VALUES_FILE")
  HOST_SHORT=$(echo "$HOSTNAME" | cut -d'.' -f1)

  echo "nmstate-host-${HOST_SHORT}-mtu${DEFAULT_MTU}-hostname: ${HOSTNAME}" >> "$OUTPUT_FILE"

  BOND_INDEX=1
  ETH_INDEX=1

  for ((i=0; i<MTU_IFACE_COUNT; i++)); do

    IF_NAME=$(yq -r ".mtu.interfaces[$i].name" "$VALUES_FILE")
    IF_TYPE=$(yq -r ".mtu.interfaces[$i].type" "$VALUES_FILE")

    if [[ "$IF_TYPE" == "bond" ]]; then
      echo "nmstate-host-${HOST_SHORT}-mtu${DEFAULT_MTU}-bond-${BOND_INDEX}: ${IF_NAME}" >> "$OUTPUT_FILE"
      echo "nmstate-host-${HOST_SHORT}-mtu${DEFAULT_MTU}-bond-${BOND_INDEX}-mtu: \"${DEFAULT_MTU}\"" >> "$OUTPUT_FILE"
      echo "nmstate-host-${HOST_SHORT}-mtu${DEFAULT_MTU}-bond-${BOND_INDEX}-mode: active-backup" >> "$OUTPUT_FILE"
      BOND_INDEX=$((BOND_INDEX+1))
    fi

    if [[ "$IF_TYPE" == "ethernet" ]]; then
      echo "nmstate-host-${HOST_SHORT}-mtu${DEFAULT_MTU}-ethernet-${ETH_INDEX}: ${IF_NAME}" >> "$OUTPUT_FILE"
      echo "nmstate-host-${HOST_SHORT}-mtu${DEFAULT_MTU}-ethernet-${ETH_INDEX}-mtu: \"${DEFAULT_MTU}\"" >> "$OUTPUT_FILE"
      ETH_INDEX=$((ETH_INDEX+1))
    fi

  done

  NNCP_COUNT=$((NNCP_COUNT+1))

done

success "Created ${NNCP_COUNT} NNCP label blocks."
success "Output written to ${OUTPUT_FILE}"