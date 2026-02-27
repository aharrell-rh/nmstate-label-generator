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

VALUES_FILE="${1:?Please provide a values file}"
FORCE="${2:-}"

BASENAME=$(basename "$VALUES_FILE" .yaml)
OUTPUT_FILE="${BASENAME}-autoshift-nmstate-labels.yaml"

BASE_IFACE="bond0"
DEFAULT_MTU=$(yq '.mtu.value // 9000' "$VALUES_FILE")

HOST_COUNT=$(yq '.hostnames | length' "$VALUES_FILE")
VLAN_COUNT=$(yq '.vlans | length' "$VALUES_FILE")

if [[ -f "$OUTPUT_FILE" && "$FORCE" != "--force" ]]; then
  if [[ -t 0 ]]; then
    echo -e "${YELLOW}WARNING:${NC} ${OUTPUT_FILE} already exists."
    read -rp "Overwrite? (y/N): " CONFIRM
    CONFIRM=$(echo "$CONFIRM" | tr '[:upper:]' '[:lower:]')
    if [[ "$CONFIRM" != "y" && "$CONFIRM" != "yes" ]]; then
      echo -e "${RED}Aborted.${NC}"
      exit 1
    fi
  else
    error "${OUTPUT_FILE} already exists and cannot prompt in non-interactive mode."
    exit 1
  fi
fi

: > "$OUTPUT_FILE"

info "Validating input file..."
info "Detected ${HOST_COUNT} host(s)"
info "Detected ${VLAN_COUNT} VLAN(s)"

if [[ "$VLAN_COUNT" -ne 2 ]]; then
  error "Exactly 2 VLANs are required. Found ${VLAN_COUNT}."
  exit 1
fi

ALL_IPS=$(yq -r '.vlans[].ips[]' "$VALUES_FILE")
DUPLICATES=$(echo "$ALL_IPS" | sort | uniq -d)

if [[ -n "$DUPLICATES" ]]; then
  error "Duplicate IP addresses detected:"
  echo "$DUPLICATES"
  exit 1
fi

for ((v=0; v<VLAN_COUNT; v++)); do
  IP_COUNT=$(yq ".vlans[$v].ips | length" "$VALUES_FILE")
  VLAN_ID=$(yq ".vlans[$v].id" "$VALUES_FILE")

  if [[ "$IP_COUNT" -ne "$HOST_COUNT" ]]; then
    error "VLAN ${VLAN_ID} has ${IP_COUNT} IP(s) but there are ${HOST_COUNT} host(s)."
    error "Each VLAN must provide exactly one IP per host."
    exit 1
  fi

  VLAN_PREFIX=$(yq ".vlans[$v].prefixLength" "$VALUES_FILE")
  if [[ -z "$VLAN_PREFIX" || "$VLAN_PREFIX" == "null" ]]; then
    error "VLAN ${VLAN_ID} is missing prefixLength."
    exit 1
  fi
done

success "Validation passed."

NNCP_ID=1

info "Generating VLAN NNCP labels..."

for ((h=0; h<HOST_COUNT; h++)); do
  HOSTNAME=$(yq -r ".hostnames[$h]" "$VALUES_FILE")

  for ((v=0; v<VLAN_COUNT; v++)); do
    VLAN_ID=$(yq ".vlans[$v].id" "$VALUES_FILE")
    VLAN_PREFIX=$(yq ".vlans[$v].prefixLength" "$VALUES_FILE")
    IP=$(yq -r ".vlans[$v].ips[$h]" "$VALUES_FILE")

    {
      echo "nmstate-host-${NNCP_ID}-hostname: ${HOSTNAME}"
      echo "nmstate-host-${NNCP_ID}-vlan-1: ${BASE_IFACE}.${VLAN_ID}"
      echo "nmstate-host-${NNCP_ID}-vlan-1-base: ${BASE_IFACE}"
      echo "nmstate-host-${NNCP_ID}-vlan-1-id: \"${VLAN_ID}\""
      echo "nmstate-host-${NNCP_ID}-vlan-1-ipv4: static"
      echo "nmstate-host-${NNCP_ID}-vlan-1-ipv4-address-1: ${IP}"
      echo "nmstate-host-${NNCP_ID}-vlan-1-ipv4-address-1-cidr: \"${VLAN_PREFIX}\""
    } >> "$OUTPUT_FILE"

    NNCP_ID=$((NNCP_ID+1))
  done
done

info "Generating MTU NNCP labels..."

MTU_IFACE_COUNT=$(yq '.mtu.interfaces | length' "$VALUES_FILE")

for ((h=0; h<HOST_COUNT; h++)); do
  HOSTNAME=$(yq -r ".hostnames[$h]" "$VALUES_FILE")
  echo "nmstate-host-${NNCP_ID}-hostname: ${HOSTNAME}" >> "$OUTPUT_FILE"

  ETH_INDEX=1
  BOND_INDEX=1

  for ((i=0; i<MTU_IFACE_COUNT; i++)); do
    IF_NAME=$(yq -r ".mtu.interfaces[$i].name" "$VALUES_FILE")
    IF_TYPE=$(yq -r ".mtu.interfaces[$i].type" "$VALUES_FILE")

    if [[ "$IF_TYPE" == "ethernet" ]]; then
      echo "nmstate-host-${NNCP_ID}-ethernet-${ETH_INDEX}: ${IF_NAME}" >> "$OUTPUT_FILE"
      echo "nmstate-host-${NNCP_ID}-ethernet-${ETH_INDEX}-mtu: \"${DEFAULT_MTU}\"" >> "$OUTPUT_FILE"
      ETH_INDEX=$((ETH_INDEX+1))
    fi

    if [[ "$IF_TYPE" == "bond" ]]; then
      echo "nmstate-host-${NNCP_ID}-bond-${BOND_INDEX}: ${IF_NAME}" >> "$OUTPUT_FILE"
      echo "nmstate-host-${NNCP_ID}-bond-${BOND_INDEX}-mtu: \"${DEFAULT_MTU}\"" >> "$OUTPUT_FILE"
      echo "nmstate-host-${NNCP_ID}-bond-${BOND_INDEX}-mode: active-backup" >> "$OUTPUT_FILE"
      BOND_INDEX=$((BOND_INDEX+1))
    fi
  done

  NNCP_ID=$((NNCP_ID+1))
done

TOTAL_NNCPS=$((NNCP_ID-1))

success "Created ${TOTAL_NNCPS} NNCP label block(s)."
success "Labels written to ${OUTPUT_FILE}"
