# Storage Cluster Networking – Autoshift Label Generator

This repository generates Autoshift-compatible NMState labels used to automate the creation of NodeNetworkConfigurationPolicy (NNCP) resources.

It converts structured cluster networking data into the flat label format required by Autoshift hub values.

---

## Purpose

When deploying storage clusters, each node typically requires:

- VLAN interfaces on a bond
- Static IP assignments
- MTU configuration (jumbo frames)
- Consistent bond and ethernet configuration

Manually generating NNCP resources or Autoshift label blocks per node does not scale.

This repository automates that process.

You define cluster networking once.  
The script expands it into the flattened label format Autoshift consumes.

---

## Data Model

The input file follows a **cluster profile model**, not a host-centric model.

It contains:

- An ordered list of hostnames
- A list of VLAN definitions
- Shared MTU and interface configuration

All VLANs and MTU settings apply to every host in the `hostnames` list.

IP addresses are assigned positionally based on hostname order.

---

## Input File Example: `example.lab.yaml`

```yaml
hostnames:
  - node1.example.lab
  - node2.example.lab

vlans:
  - id: 100
    ips:
      - 192.168.1.1
      - 192.168.1.2
    prefixLength: 24

  - id: 101
    ips:
      - 192.168.2.1
      - 192.168.2.2
    prefixLength: 25

mtu:
  value: 9000
  interfaces:
    - name: eno1
      type: ethernet
    - name: eno2
      type: ethernet
    - name: bond0
      type: bond
```

---

## How IP Assignment Works

IP assignment is positional.

The order of `hostnames` must match the order of IPs inside each VLAN.

Example mapping:

| Host                | VLAN 100 IP | VLAN 101 IP |
|---------------------|-------------|-------------|
| node1.example.lab   | 192.168.1.1 | 192.168.2.1 |
| node2.example.lab   | 192.168.1.2 | 192.168.2.2 |

The script uses the index of the hostname to select the corresponding IP in each VLAN list.

---

## What the Script Does

The `generate-labels.sh` script:

1. Reads `example.lab.yaml`
2. Iterates over each hostname
3. Applies MTU configuration to defined interfaces
4. Configures bond settings (if defined)
5. Iterates over each VLAN
6. Assigns the IP matching the hostname index
7. Generates flattened NMState label entries
8. Outputs a file formatted for Autoshift

This effectively performs:

```
hostnames × vlans
```

Plus shared interface configuration.

---

## Generating the Labels

Run the following command from the repository root:

```bash
sh generate-labels.sh example.lab.yaml
```

This generates:

```
example.lab-autoshift-nmstate-label.yaml
```

This output file contains the flattened label structure required by Autoshift.

---

## Example of Generated Output

```yaml
nmstate-host-1-hostname: node1.example.lab
nmstate-host-1-vlan-1: bond0.100
nmstate-host-1-vlan-1-base: bond0
nmstate-host-1-vlan-1-id: "100"
nmstate-host-1-vlan-1-ipv4: static
nmstate-host-1-vlan-1-ipv4-address-1: 192.168.1.1
nmstate-host-1-vlan-1-ipv4-address-1-cidr: "24"

nmstate-host-2-hostname: node2.example.lab
nmstate-host-2-vlan-1: bond0.100
nmstate-host-2-vlan-1-base: bond0
nmstate-host-2-vlan-1-id: "100"
nmstate-host-2-vlan-1-ipv4: static
nmstate-host-2-vlan-1-ipv4-address-1: 192.168.1.2
nmstate-host-2-vlan-1-ipv4-address-1-cidr: "24"
```

Each block represents:

- A specific host
- A specific VLAN interface
- Static IP configuration
- MTU and interface settings

You do not manually write this.  
The script generates it deterministically.

---

## How Autoshift Uses the Output

The generated file is not applied directly to the cluster.

Instead:

1. Copy the generated label block into your Autoshift hub values file
2. Commit and push
3. Let ACM/Autoshift render the policies

Autoshift then:

- Selects nodes via labels
- Generates NodeNetworkConfigurationPolicy resources
- Applies configuration through NMState

No manual NNCP authoring required.

---

## Dependency

This repository requires:

- `yq` for YAML parsing and transformation

Install on RHEL or Fedora:

```bash
dnf install yq
```

---

## Future Automation

Currently, `example.lab.yaml` is manually created using:

- Hostnames from Cisco Intersight
- VLAN/IP allocation data from the networking team

A future enhancement would:

- Pull host inventory directly from the Intersight API
- Merge it with VLAN/IP allocations
- Automatically generate the input YAML

Target end state:

Intersight API + Networking data → Auto-generated input → Label generation → Autoshift → NNCP

---

## Summary

This repository:

- Eliminates manual NNCP label creation
- Ensures consistent host-to-VLAN mapping
- Enforces ordered IP assignment
- Scales cleanly across storage clusters
- Separates structured data definition from configuration generation

Workflow recap:

Create input YAML → Run script → Generate labels → Insert into Autoshift values → Autoshift applies configuration automatically