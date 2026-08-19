# VLAN 20 Switch Configuration

Manual switch config for VLAN 20 (Homelab, 10.0.69.0/24). Companion to [VLANS.md](./VLANS.md).

## Topology

```
pfSense
  └── Unifi 24p (trunk: VLAN 1+20)
        ├── GS108T (trunk: VLAN 1+20)
        │     ├── hades NIC1 (access VLAN 1)
        │     └── hades NIC2 (access VLAN 20) ← NEW
        ├── GS724Tv4 (trunk: VLAN 1+20)
        │     ├── zeus (access VLAN 20)
        │     └── gaea (access VLAN 20)
        ├── pik8s4 (access VLAN 20)
        ├── pik8s5 (access VLAN 20)
        ├── pik8s6 (access VLAN 20)
        └── agreus (access VLAN 20)
```

## Order of Operations

1. **GS108T** — trunk + hades NIC2 port (NIC1 stays up throughout)
2. **Unifi** — create network, trunk ports first, then access ports
3. **GS724Tv4** — trunk + move zeus/gaea ports last

---

## GS108T

Web UI: `http://<gs108t-ip>` → admin login

**Identify ports first:**
- Port A = uplink to Unifi 24p
- Port B = hades NIC1 (existing)
- Port C = hades NIC2 (plug cable in before configuring)

### 1. Add VLAN 20

`Switching > VLAN > 802.1Q > Advanced > VLAN Configuration`

- Click Add
- VLAN ID: `20`, Name: `Homelab`
- Save

### 2. VLAN 1 membership

`Switching > VLAN > 802.1Q > Advanced > VLAN Membership` → select VLAN 1

| Port | Membership |
|------|-----------|
| Port A (uplink) | T |
| Port B (hades NIC1) | U |
| Port C (hades NIC2) | — |
| All others | U |

### 3. VLAN 20 membership

Same page → select VLAN 20

| Port | Membership |
|------|-----------|
| Port A (uplink) | T |
| Port B (hades NIC1) | — |
| Port C (hades NIC2) | U |
| All others | — |

### 4. PVIDs

`Switching > VLAN > 802.1Q > Advanced > Port PVID Configuration`

| Port | PVID |
|------|------|
| Port A (uplink) | 1 |
| Port B (hades NIC1) | 1 |
| Port C (hades NIC2) | **20** |
| All others | 1 |

Apply. No reboot needed.

---

## Unifi Switch

Access: UniFi Controller UI

**Identify ports first:**
- Port P = pfSense uplink
- Port G1 = GS108T uplink
- Port G2 = GS724Tv4 uplink
- Ports K4, K5, K6 = pik8s4, pik8s5, pik8s6
- Port AG = agreus

### 1. Create Homelab network

`Settings > Networks > Add New Network`

- Name: `Homelab`
- Purpose: `VLAN Only` (pfSense handles routing/DHCP)
- VLAN: `20`
- Save

### 2. Configure ports

`Devices > [switch] > Ports`

**Access ports** (pik8s4, pik8s5, pik8s6, agreus):
- Native Network: `Homelab`
- Tagged Networks: _(none)_

**Trunk ports** (pfSense uplink, GS108T uplink, GS724Tv4 uplink):
- Native Network: `Default`
- Tagged Networks: `Homelab`

### 3. Provision

Provision switch. Brief traffic blip expected.

---

## GS724Tv4

Web UI: `http://<gs724t-ip>` → admin login

**Identify ports first:**
- Port U = uplink to Unifi 24p
- Port Z = zeus
- Port G = gaea

### 1. Add VLAN 20

`Switching > VLAN > 802.1Q > Advanced > VLAN Configuration`

- Add VLAN ID: `20`, Name: `Homelab`
- Save

### 2. VLAN 1 membership

Select VLAN 1:

| Port | Membership |
|------|-----------|
| Port U (uplink) | T |
| Port Z (zeus) | — |
| Port G (gaea) | — |
| All others | U |

### 3. VLAN 20 membership

Select VLAN 20:

| Port | Membership |
|------|-----------|
| Port U (uplink) | T |
| Port Z (zeus) | U |
| Port G (gaea) | U |
| All others | — |

### 4. PVIDs

`Switching > VLAN > 802.1Q > Advanced > Port PVID Configuration`

| Port | PVID |
|------|------|
| Port U (uplink) | 1 |
| Port Z (zeus) | **20** |
| Port G (gaea) | **20** |
| All others | 1 |

Apply.

---

## Verification

After NixOS config deployed to hades:

```bash
# 2nd NIC on VLAN 20
ip addr show <2nd-nic>

# Reach pfSense homelab gateway
ping 10.0.69.1

# Once pik8s nodes redeployed
ping 10.0.69.104
ssh root@10.0.69.104
```
