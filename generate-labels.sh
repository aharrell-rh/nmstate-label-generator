#!/usr/bin/env bash
set -euo pipefail

VALUES_FILE="${1:?Provide values.yaml}"

BASENAME=$(basename "$VALUES_FILE" .yaml)
OUTPUT_FILE="${BASENAME}-nmstate-config.yaml"

# Read inputs
HOSTS=$(yq -r '.hostnames[]' "$VALUES_FILE")
MTU=$(yq '.mtu.value // 9000' "$VALUES_FILE")
INTERFACES_COUNT=$(yq '.mtu.interfaces | length' "$VALUES_FILE")
VLAN_COUNT=$(yq '.vlans | length' "$VALUES_FILE")

: > "$OUTPUT_FILE"

echo "config:" >> "$OUTPUT_FILE"
echo "  networking:" >> "$OUTPUT_FILE"

########################################
# Interfaces (topology)
########################################
echo "    interfaces:" >> "$OUTPUT_FILE"

ETH_INDEX=1
BOND_DEFINED=false

for ((i=0; i<INTERFACES_COUNT; i++)); do
  TYPE=$(yq -r ".mtu.interfaces[$i].type" "$VALUES_FILE")
  MAC=$(yq -r ".mtu.interfaces[$i].mac" "$VALUES_FILE")

  if [[ "$TYPE" == "ethernet" ]]; then
    echo "      port${ETH_INDEX}:" >> "$OUTPUT_FILE"
    echo "        type: ethernet" >> "$OUTPUT_FILE"
    echo "        mac: ${MAC}" >> "$OUTPUT_FILE"
    echo "        mtu: ${MTU}" >> "$OUTPUT_FILE"
    ETH_INDEX=$((ETH_INDEX+1))
  fi

  if [[ "$TYPE" == "bond" ]]; then
    BOND_DEFINED=true
  fi
done

# Auto-create bond if at least 2 ethernet ports exist
if [[ "$ETH_INDEX" -gt 2 ]]; then
  echo "      mgmt:" >> "$OUTPUT_FILE"
  echo "        type: bond" >> "$OUTPUT_FILE"
  echo "        name: bond0" >> "$OUTPUT_FILE"
  echo "        mode: active-backup" >> "$OUTPUT_FILE"

  PORT_LIST=""
  for ((p=1; p<ETH_INDEX; p++)); do
    PORT_LIST+="port${p}, "
  done
  PORT_LIST="[${PORT_LIST%, }]"

  echo "        ports: ${PORT_LIST}" >> "$OUTPUT_FILE"
  echo "        mtu: ${MTU}" >> "$OUTPUT_FILE"
  echo "        ipv4: disabled" >> "$OUTPUT_FILE"
  echo "        ipv6: disabled" >> "$OUTPUT_FILE"
fi

########################################
# VLANs (topology)
########################################
for ((v=0; v<VLAN_COUNT; v++)); do
  VLAN_ID=$(yq ".vlans[$v].id" "$VALUES_FILE")

  echo "      vlan${VLAN_ID}:" >> "$OUTPUT_FILE"
  echo "        type: vlan" >> "$OUTPUT_FILE"
  echo "        name: bond0.${VLAN_ID}" >> "$OUTPUT_FILE"
  echo "        id: ${VLAN_ID}" >> "$OUTPUT_FILE"
  echo "        base: bond0" >> "$OUTPUT_FILE"
  echo "        ipv4: static" >> "$OUTPUT_FILE"
  echo "        ipv6: disabled" >> "$OUTPUT_FILE"
done

########################################
# Hosts (per-host overrides)
########################################
echo "    hosts:" >> "$OUTPUT_FILE"

HOST_INDEX=0

for HOST in $HOSTS; do
  echo "      ${HOST}:" >> "$OUTPUT_FILE"
  echo "        networking:" >> "$OUTPUT_FILE"
  echo "          interfaces:" >> "$OUTPUT_FILE"

  for ((v=0; v<VLAN_COUNT; v++)); do
    VLAN_ID=$(yq ".vlans[$v].id" "$VALUES_FILE")
    PREFIX=$(yq ".vlans[$v].prefixLength" "$VALUES_FILE")
    IP=$(yq -r ".vlans[$v].ips[$HOST_INDEX]" "$VALUES_FILE")

    echo "            vlan${VLAN_ID}:" >> "$OUTPUT_FILE"
    echo "              ipv4:" >> "$OUTPUT_FILE"
    echo "                addresses:" >> "$OUTPUT_FILE"
    echo "                  - ip: ${IP}" >> "$OUTPUT_FILE"
    echo "                    prefixLength: ${PREFIX}" >> "$OUTPUT_FILE"
  done

  HOST_INDEX=$((HOST_INDEX+1))
done

echo ""
echo "Generated: ${OUTPUT_FILE}"