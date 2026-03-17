#!/usr/bin/env bash
set -euo pipefail

INPUT_FILE="${1:?Provide input yaml}"
OUTPUT_FILE="nmstate-config.yaml"

MTU=$(yq '.mtu.value // 9000' "$INPUT_FILE")
BOND_NAME=$(yq -r '.mtu.bond.name // "bond0"' "$INPUT_FILE")
BOND_MODE=$(yq -r '.mtu.bond.mode // "active-backup"' "$INPUT_FILE")

HOST_COUNT=$(yq '.hosts | length' "$INPUT_FILE")
VLAN_COUNT=$(yq '.vlans | length' "$INPUT_FILE")

: > "$OUTPUT_FILE"

echo "hosts:" >> "$OUTPUT_FILE"

########################################
# Loop hosts
########################################
for ((h=0; h<HOST_COUNT; h++)); do

  HOSTNAME=$(yq -r ".hosts[$h].hostname" "$INPUT_FILE")
  SHORT=$(echo "$HOSTNAME" | cut -d'.' -f1)

  MAC1=$(yq -r ".hosts[$h].interfaces.mac1" "$INPUT_FILE")
  MAC2=$(yq -r ".hosts[$h].interfaces.mac2" "$INPUT_FILE")

  echo "  ${SHORT}:" >> "$OUTPUT_FILE"
  echo "    hostname: ${HOSTNAME}" >> "$OUTPUT_FILE"
  echo "    networking:" >> "$OUTPUT_FILE"
  echo "      interfaces:" >> "$OUTPUT_FILE"

  ########################################
  # MAC1 → port1
  ########################################
  echo "        - identifier: mac-address" >> "$OUTPUT_FILE"
  echo "          mac-address: \"${MAC1}\"" >> "$OUTPUT_FILE"
  echo "          name: port1" >> "$OUTPUT_FILE"
  echo "          type: ethernet" >> "$OUTPUT_FILE"
  echo "          state: up" >> "$OUTPUT_FILE"
  echo "          mtu: ${MTU}" >> "$OUTPUT_FILE"
  echo "" >> "$OUTPUT_FILE"

  ########################################
  # MAC2 → port2
  ########################################
  echo "        - identifier: mac-address" >> "$OUTPUT_FILE"
  echo "          mac-address: \"${MAC2}\"" >> "$OUTPUT_FILE"
  echo "          name: port2" >> "$OUTPUT_FILE"
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
  echo "              - port1" >> "$OUTPUT_FILE"
  echo "              - port2" >> "$OUTPUT_FILE"
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

done

echo "Generated ${OUTPUT_FILE}"