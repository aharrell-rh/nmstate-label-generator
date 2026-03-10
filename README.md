# Storage Cluster Networking – Autoshift Label Generator

This repository generates Autoshift-compatible NMState labels used to automate the creation of NodeNetworkConfigurationPolicy (NNCP) resources.

It converts structured cluster networking data into the flat label format required by Autoshift hub values.

---

## Purpose

When deploying storage clusters, each node typically requires:

- VLAN interfaces on a bond
- Static IP assignments per host
- MTU configuration (jumbo frames)
- MAC-based ethernet identification for stable NIC matching

Manually generating NNCP resources or Autoshift label blocks per node does not scale.

This repository automates that process.

You define cluster networking once.
The script expands it into the flattened label format Autoshift consumes.

---

## Data Model

The input file follows a **cluster profile model**.

It contains:

- An ordered list of hosts, each with a hostname and per-host ethernet interfaces (including MAC addresses)
- A list of VLAN definitions with per-host IP assignments
- Shared MTU and bond configuration

All VLANs and MTU settings apply to every host in the `hosts` list.

IP addresses are assigned positionally based on host order.

MAC addresses are per-host because physical NICs differ between nodes.

---

## Input File Example: `example.lab.yaml`

```yaml
hosts:
  - hostname: node1.example.lab
    interfaces:
      - name: eno1
        mac: "aa:bb:cc:dd:ee:01"
        type: ethernet
      - name: eno2
        mac: "aa:bb:cc:dd:ee:02"
        type: ethernet
  - hostname: node2.example.lab
    interfaces:
      - name: eno1
        mac: "aa:bb:cc:dd:ee:03"
        type: ethernet
      - name: eno2
        mac: "aa:bb:cc:dd:ee:04"
        type: ethernet

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
  bond:
    name: bond0
    mode: active-backup
```

MAC addresses can be written with colons in the input file. The script automatically converts them to dot notation required by Kubernetes labels.

---

## How IP Assignment Works

IP assignment is positional.

The order of `hosts` must match the order of IPs inside each VLAN.

Example mapping:

| Host              | VLAN 100 IP | VLAN 101 IP |
|-------------------|-------------|-------------|
| node1.example.lab | 192.168.1.1 | 192.168.2.1 |
| node2.example.lab | 192.168.1.2 | 192.168.2.2 |

The script uses the index of the host to select the corresponding IP in each VLAN list.

---

## What the Script Does

The `generate-labels.sh` script:

1. Reads the input YAML file
2. Validates there are no duplicate IPs and every VLAN has exactly one IP per host
3. Iterates over each host and VLAN to generate per-host VLAN label blocks
4. Iterates over each host to generate MTU label blocks covering the bond and all ethernet interfaces
5. Outputs a file formatted for Autoshift

This effectively performs:

```
hosts × vlans  (VLAN blocks)
hosts × interfaces  (MTU blocks)
```

---

## Generating the Labels

Run the following command from the repository root:

```bash
sh generate-labels.sh example.lab.yaml
```

To overwrite an existing output file without prompting:

```bash
sh generate-labels.sh example.lab.yaml --force
```

This generates:

```
example.lab-autoshift-nmstate-labels.yaml
```

---

## Example of Generated Output

For each host the script produces two groups of label blocks.

**VLAN blocks** (one per host per VLAN):

```yaml
nmstate-host-node1-vlan100-hostname: node1.example.lab
nmstate-host-node1-vlan100-vlan-1: bond0.100
nmstate-host-node1-vlan100-vlan-1-base: bond0
nmstate-host-node1-vlan100-vlan-1-id: "100"
nmstate-host-node1-vlan100-vlan-1-ipv4: static
nmstate-host-node1-vlan100-vlan-1-ipv4-address-1: 192.168.1.1
nmstate-host-node1-vlan100-vlan-1-ipv4-address-1-cidr: "24"
```

**MTU blocks** (one per host, covering bond + all ethernet interfaces):

```yaml
nmstate-host-node1-mtu9000-hostname: node1.example.lab
nmstate-host-node1-mtu9000-bond-1: bond0
nmstate-host-node1-mtu9000-bond-1-mtu: "9000"
nmstate-host-node1-mtu9000-bond-1-mode: active-backup
nmstate-host-node1-mtu9000-ethernet-1: eno1
nmstate-host-node1-mtu9000-ethernet-1-mac: aa.bb.cc.dd.ee.01
nmstate-host-node1-mtu9000-ethernet-1-mtu: "9000"
nmstate-host-node1-mtu9000-ethernet-2: eno2
nmstate-host-node1-mtu9000-ethernet-2-mac: aa.bb.cc.dd.ee.02
nmstate-host-node1-mtu9000-ethernet-2-mtu: "9000"
```

Because ethernet labels include a MAC address, Autoshift will render `identifier: mac-address` in the resulting NNCP. NMState matches each NIC by MAC and uses the `name` as the NetworkManager profile name, ensuring stable NIC matching regardless of kernel interface naming.

---

## How Autoshift Uses the Output

The generated file is not applied directly to the cluster.

Instead:

1. Copy the generated label block into your Autoshift hub values file
2. Commit and push
3. Let ACM/Autoshift render the policies

Autoshift then:

- Selects nodes via hostname nodeSelector
- Generates NodeNetworkConfigurationPolicy resources
- Applies configuration through NMState

No manual NNCP authoring required.

---

## Dependency

This repository requires `yq` for YAML parsing.

Install on RHEL:

```bash
dnf install yq
```

---

## Future Automation

Currently the input YAML is manually created using:

- Hostnames and MAC addresses from Cisco Intersight
- VLAN/IP allocation data from the networking team

A future enhancement would:

- Pull host inventory and MAC addresses directly from the Intersight API
- Merge with VLAN/IP allocations
- Automatically generate the input YAML

Target end state:

```
Intersight API + Networking data → Auto-generated input → Label generation → Autoshift → NNCP
```

---

## Summary

This repository:

- Eliminates manual NNCP label creation
- Ensures consistent host-to-VLAN IP mapping
- Enforces ordered IP assignment
- Generates MAC-based ethernet labels for stable NIC identification
- Scales cleanly across storage clusters
- Separates structured data definition from configuration generation

Workflow recap:

```
Create input YAML → Run script → Generate labels → Insert into Autoshift values → Autoshift applies configuration automatically
```