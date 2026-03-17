#!/usr/bin/env bash
set -euo pipefail

########################################
# Colors
########################################
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

########################################
# Args
########################################
INPUT_FILE="${1:?Provide input yaml}"
FORCE="${2:-}"

BASENAME=$(basename "$INPUT_FILE" .yaml)
OUTPUT_FILE="${BASENAME}-autoshift-nmstate.yaml"

########################################
# Defaults
########################################
MTU=$(yq '.mtu.value // 9000' "$INPUT_FILE")
BOND_NAME=$(yq -r '.mtu.bond.name // "bond0"' "$INPUT_FILE")
BOND_MODE=$(yq -r '.mtu.bond.mode // "active-backup"' "$INPUT_FILE")

HOST_COUNT=$(yq '.hosts | length' "$INPUT_FILE")
VLAN_COUNT=$(yq '.vlans | length' "$INPUT_FILE")

########################################
# Overwrite protection
########################################
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

########################################
# Validation
########################################
info "Validating input..."

# Duplicate IP check
ALL_IPS=$(yq -r '.vlans[].ips[]' "$INPUT_FILE")
DUPES=$(echo "$ALL_IPS" | sort | uniq -d)

if [[ -n "$DUPES" ]]; then
  error "Duplicate IPs detected:"
  echo "$DUPES"
  exit 1
fi

# VLAN IP count must match hosts
for ((v=0; v<VLAN_COUNT; v++)); do
  VLAN_ID=$(yq ".vlans[$v].id" "$INPUT_FILE")
  IP_COUNT=$(yq ".vlans[$v].ips | length" "$INPUT_FILE")

  if [[ "$IP_COUNT" -ne "$HOST_COUNT" ]]; then
    error "VLAN ${VLAN_ID} has ${IP_COUNT} IPs but ${HOST_COUNT} hosts."
    exit 1
  fi
done

success "Validation passed."

########################################
# Generation
########################################
info "Generating NMState config..."

echo "hosts:" >> "$OUTPUT_FILE"

NNCP_COUNT=0

for ((h=0; h<HOST_COUNT; h++)); do

  HOSTNAME=$(yq -r ".hosts[$h].hostname" "$INPUT_FILE")
  SHORT=$(echo "$HOSTNAME" | cut -d'.' -f1)

  MAC1=$(yq -r ".hosts[$h].interfaces.mac1" "$INPUT_FILE")
  MAC2=$(yq -r ".hosts[$h].interfaces.mac2" "$INPUT_FILE")

  ########################################
  # Host block
  ########################################
  echo "  ${SHORT}:" >> "$OUTPUT_FILE"
  echo "    hostname: ${HOSTNAME}" >> "$OUTPUT_FILE"
  echo "    networking:" >> "$OUTPUT_FILE"
  echo "      interfaces:" >> "$OUTPUT_FILE"

  ########################################
  # eno6
  ########################################
  echo "        - identifier: mac-address" >> "$OUTPUT_FILE"
  echo "          mac-address: \"${MAC1}\"" >> "$OUTPUT_FILE"
  echo "          name: eno6" >> "$OUTPUT_FILE"
  echo "          type: ethernet" >> "$OUTPUT_FILE"
  echo "          state: up" >> "$OUTPUT_FILE"
  echo "          mtu: ${MTU}" >> "$OUTPUT_FILE"
  echo "" >> "$OUTPUT_FILE"

  ########################################
  # eno7
  ########################################
  echo "        - identifier: mac-address" >> "$OUTPUT_FILE"
  echo "          mac-address: \"${MAC2}\"" >> "$OUTPUT_FILE"
  echo "          name: eno7" >> "$OUTPUT_FILE"
  echo "          type: ethernet" >> "$OUTPUT_FILE"
  echo "          state: up" >> "$OUTPUT_FILE"
  echo "          mtu: ${MTU}" >> "$OUTPUT_FILE"
  echo "" >> "$OUTPUT_FILE"

  ########################################
  # Bond
  ########################################
  echo "        - name: ${BOND_NAME}" >> "$OUTPUT_FILE"
  echo "          type: bond" >> "$OUTPUT_FILE"
  echo "          state: up" >> "$OUTPUT_FILE"
  echo "          mtu: ${MTU}" >> "$OUTPUT_FILE"
  echo "          link-aggregation:" >> "$OUTPUT_FILE"
  echo "            mode: ${BOND_MODE}" >> "$OUTPUT_FILE"
  echo "            port:" >> "$OUTPUT_FILE"
  echo "              - eno6" >> "$OUTPUT_FILE"
  echo "              - eno7" >> "$OUTPUT_FILE"
  echo "" >> "$OUTPUT_FILE"

  ########################################
  # VLANs
  ########################################
  for ((v=0; v<VLAN_COUNT; v++)); do

    VLAN_ID=$(yq ".vlans[$v].id" "$INPUT_FILE")
    PREFIX=$(yq ".vlans[$v].prefixLength" "$INPUT_FILE")
    IP=$(yq -r ".vlans[$v].ips[$h]" "$INPUT_FILE")

    echo "        - name: ${BOND_NAME}.${VLAN_ID}" >> "$OUTPUT_FILE"
    echo "          type: vlan" >> "$OUTPUT_FILE"
    echo "          state: up" >> "$OUTPUT_FILE"
    echo "          mtu: ${MTU}" >> "$OUTPUT_FILE"
    echo "          vlan:" >> "$OUTPUT_FILE"
    echo "            base-iface: ${BOND_NAME}" >> "$OUTPUT_FILE"
    echo "            id: ${VLAN_ID}" >> "$OUTPUT_FILE"
    echo "          ipv4:" >> "$OUTPUT_FILE"
    echo "            enabled: true" >> "$OUTPUT_FILE"
    echo "            dhcp: false" >> "$OUTPUT_FILE"
    echo "            address:" >> "$OUTPUT_FILE"
    echo "              - ip: ${IP}" >> "$OUTPUT_FILE"
    echo "                prefix-length: ${PREFIX}" >> "$OUTPUT_FILE"
    echo "" >> "$OUTPUT_FILE"

  done

  NNCP_COUNT=$((NNCP_COUNT+1))

done

########################################
# Done
########################################
success "Created ${NNCP_COUNT} host configurations."
success "Output written to ${OUTPUT_FILE}"
