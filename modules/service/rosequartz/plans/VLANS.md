# VLAN Segmentation: Personal LAN vs Homelab

## Context

Currently all devices share 192.168.1.0/24 (flat L2). Goal: isolate k8s cluster nodes into a dedicated homelab VLAN so personal traffic and homelab traffic are on separate L2 domains. Doing this now (before rosequartz is deployed) avoids IP changes post-cert-deployment.

## VLAN Scheme

| VLAN | Name | Subnet | Gateway |
|------|------|--------|---------|
| 1 (native) | Personal | 192.168.1.0/24 | 192.168.1.1 |
| 20 | Homelab | 10.0.69.0/24 | 10.0.69.1 |

No CIDR conflicts: k8s service CIDR defaults to 10.0.0.0/24, pod CIDR to 10.244.0.0/16 — neither overlaps 10.0.69.0/24.

## New IP Addresses

| Node | Old IP | New IP |
|------|--------|--------|
| pik8s4 | 192.168.1.104 | 10.0.69.104 |
| pik8s5 | 192.168.1.105 | 10.0.69.105 |
| pik8s6 | 192.168.1.106 | 10.0.69.106 |
| agreus | 192.168.1.187 | 10.0.69.187 |
| rosequartz VIP | 192.168.1.100 | 10.0.69.100 |

## Phase 1: Switch/Router Config (manual, out-of-band)

### pfSense SBC

#### Interface assignment
1. `Interfaces > Assignments > VLANs > Add`: Parent = Unifi uplink NIC, VLAN Tag = `20`,
   Description = `Homelab`.
2. `Interfaces > Assignments`: assign the new VLAN, then open it and:
   - Enable interface, name it `HOMELAB`.
   - IPv4 Configuration Type = `Static IPv4`, address `10.0.69.1/24`.
   - IPv6 Configuration Type = `None` (this VLAN is IPv4-only; leave RA/DHCPv6 off).
3. (Optional) `Services > DHCP Server > HOMELAB`: enable, range e.g. `10.0.69.150–.199`.
   Nodes use static IPs outside this range, so DHCP is only for convenience.

#### Firewall rules — important gotchas

pfSense evaluates rules on a tab **top-to-bottom, first match wins**, and rules filter
traffic **entering** that interface (i.e. sourced from that VLAN). A brand-new interface tab
is empty and has an implicit *deny-all*, so all traffic is dropped until you add pass rules
(this is why ping failed initially). Key consequences:

- Put **specific block rules ABOVE broad allow rules**. An "allow Homelab → any" rule placed
  first will match and permit traffic to the Personal VLAN before a later "block → Personal"
  rule is ever evaluated. Order is: allow-to-firewall → block-to-other-RFC1918 → allow-internet.
- "Homelab → internet: allow" really means "allow to *any*". To keep it from also reaching
  Personal (192.168.1.0/24) and other private ranges, block those **first**.
- Rules for **Personal → Homelab** (SSH/kubectl) live on the **LAN/Personal interface tab**,
  not the HOMELAB tab, because that traffic enters pfSense from the Personal VLAN.
- `HOMELAB net` = the 10.0.69.0/24 subnet. `HOMELAB address` / `This Firewall` = the gateway
  itself (10.0.69.1); use the latter to scope DNS/ping to the firewall.

#### Rules on the HOMELAB tab (`Firewall > Rules > HOMELAB`), in order

| # | Action | Proto | Source | Destination | Port | Purpose |
|---|--------|-------|--------|-------------|------|---------|
| 1 | Pass | ICMP (echoreq) | HOMELAB net | This Firewall | — | Ping the gateway (troubleshooting) |
| 2 | Pass | TCP/UDP | HOMELAB net | This Firewall | 53 | DNS to pfSense resolver |
| 3 | Pass | UDP | HOMELAB net | This Firewall | 123 | NTP (optional) |
| 4 | Block | any | HOMELAB net | This Firewall | — | Deny all other access to pfSense (web UI/SSH) |
| 5 | Block | any | HOMELAB net | Personal net (192.168.1.0/24) | — | Homelab → Personal isolation |
| 6 | Block | any | HOMELAB net | RFC1918 alias (10/8, 172.16/12, 192.168/16) | — | Block other private ranges, keep internet |
| 7 | Pass | any | HOMELAB net | any | — | Homelab → internet |

Notes:
- Rules 5/6 overlap; a single **block to an `RFC1918` alias** (defining 10.0.0.0/8,
  172.16.0.0/12, 192.168.0.0/16) covers both. Exclude `HOMELAB net` from that alias, or add a
  pass rule for intra-VLAN 20 traffic above it, so Ceph/k8s replication inside 10.0.69.0/24 is
  not blocked (intra-subnet traffic doesn't route through pfSense anyway, but the alias-based
  block is a footgun if you later add a second homelab subnet).
- If DNS/ping to the gateway isn't needed, rules 1–4 collapse to a single "block to This
  Firewall" — but then hades can't `ping 10.0.69.1` as a reachability test.

#### Rules on the Personal/LAN tab (`Firewall > Rules > LAN`)

Add these **above** the default "allow LAN to any" rule (or they'll never be evaluated
differently — allow-any already permits them, but list them explicitly if you later tighten
the Personal tab):

| Action | Proto | Source | Destination | Port | Purpose |
|--------|-------|--------|-------------|------|---------|
| Pass | TCP | Personal net | HOMELAB net | 22 | SSH to nodes |
| Pass | TCP | Personal net | 10.0.69.100 (VIP) | 6443 | kubectl to rosequartz API |

- Storage/Ceph replication traffic stays intra-VLAN 20 and never hits pfSense, so no rule is
  needed for it.
- Remember to **Apply Changes** after editing rules; pfSense stages them until applied.

### Unifi 24p (via UniFi Controller)
1. Create Network: "Homelab", VLAN 20
2. pik8s4/5/6 ports: set to VLAN 20 untagged (access port)
3. agreus port: set to VLAN 20 untagged (access port)
4. pfSense uplink port: trunk — tagged VLAN 1 + VLAN 20
5. GS108T uplink port: trunk — tagged VLAN 1 + VLAN 20

### GS108T
1. Uplink port to Unifi: 802.1Q trunk, pass VLAN 1 (tagged) + VLAN 20 (tagged)
2. hades (workstation) port: PVID 1, VLAN 1 untagged (access)
3. Other ports: VLAN 1 untagged unless they need homelab access

## Phase 2: NixOS Config Changes

### machines/pik8s4/configuration.nix
```nix
networking = {
  hostName = "pik8s4";
  defaultGateway = {
    address = "10.0.69.1";  # was missing!
    interface = "end0";
  };
  nameservers = [ "10.0.69.1" ];  # pfSense homelab gateway; replace with CoreDNS VIP once cluster up
  interfaces.end0 = {
    useDHCP = false;
    ipv4.addresses = [{
      address = "10.0.69.104";
      prefixLength = 24;
    }];
  };
};
cluster.rosequartz = {
  interface = "end0";
  advertiseAddress = "10.0.69.104";
  keepalivedPriority = 100;
  etcd.advertiseClientUrls = [ "https://10.0.69.104:2379" ];
  etcd.initialAdvertisePeerUrls = [ "https://10.0.69.104:2380" ];
};
```

### machines/pik8s5/configuration.nix
Same pattern: IP 10.0.69.105, priority 90.

### machines/pik8s6/configuration.nix
Same pattern: IP 10.0.69.106, priority 80.

### machines/agreus/configuration.nix
- Add static IP config for the homelab interface (currently no interface stanza):
```nix
networking = {
  hostName = "agreus";
  useDHCP = false;
  defaultGateway = {
    address = "10.0.69.1";
    interface = "<iface>";  # check facter.json for interface name
  };
  nameservers = [ "10.0.69.1" ];  # pfSense homelab gateway; replace with CoreDNS VIP once cluster up
  interfaces.<iface>.ipv4.addresses = [{
    address = "10.0.69.187";
    prefixLength = 24;
  }];
};
cluster.rosequartz.advertiseAddress = "10.0.69.187";
```
Note: check `machines/agreus/facter.json` for the ethernet interface name (likely `enp*` or `eth0`).

### clan.nix
Update `deploy.targetHost` and rosequartz settings:
```nix
# pik8s4/5/6 targetHost entries:
deploy.targetHost = "root@10.0.69.104";  # 105, 106

# agreus:
deploy.targetHost = "root@10.0.69.187";

# inventory.instances.rosequartz:
roles.control-plane.settings.vip = "10.0.69.100";
roles.control-plane.machines.pik8s4.settings.ip = "10.0.69.104";
roles.control-plane.machines.pik8s5.settings.ip = "10.0.69.105";
roles.control-plane.machines.pik8s6.settings.ip = "10.0.69.106";
roles.worker.machines.agreus.settings.ip = "10.0.69.187";
```

## Phase 3: Cert Regen

Some rosequartz certs include node IPs in their SANs. After IP changes, these must be
regenerated. Note two gotchas:

- `clan vars generate`'s positional argument is a **machine** name, not a service instance
  (`rosequartz` is not a machine).
- By default clan only generates **missing** vars; existing cert files are skipped. Pass
  `--regenerate`/`-r` to force overwrite.

Only these generators embed IPs and need regenerating (the CA uses interactive prompts and
must NOT be regenerated, or it will ask for the CA PEM again):

- shared: `rosequartz-apiserver-cert` (VIP + all node IPs)
- pik8s4/5/6: `rosequartz-etcd-server-cert`, `rosequartz-etcd-peer-cert`, `rosequartz-kubelet-cert`
- agreus: `rosequartz-worker-kubelet-cert`

Regenerate just those (targeting with `-g` avoids re-prompting the CA — dependencies are used,
not regenerated):
```
# shared apiserver cert (run once, on any control-plane machine)
clan vars generate -r -g rosequartz-apiserver-cert pik8s4

# per-machine etcd + kubelet certs
for m in pik8s4 pik8s5 pik8s6; do
  clan vars generate -r -g rosequartz-etcd-server-cert "$m"
  clan vars generate -r -g rosequartz-etcd-peer-cert  "$m"
  clan vars generate -r -g rosequartz-kubelet-cert    "$m"
done

# agreus worker kubelet cert
clan vars generate -r -g rosequartz-worker-kubelet-cert agreus
```

## Deploy Order (avoid losing SSH access)

Use `nixos-rebuild boot` (not switch) to stage configs, then change switch port, then reboot:

For each node:
1. `nixos-rebuild boot --target-host root@<old-ip> --flake .#<machine>` — stages new config, no immediate effect
2. Change Unifi port to VLAN 20 in controller
3. Reboot node — comes up with new IP on correct VLAN

Verify after each node before proceeding to next. Deploy pik8s4 → pik8s5 → pik8s6 → agreus.

## Verification

1. `ping 10.0.69.104` from hades — tests routing through pfSense
2. `ssh root@10.0.69.104` — confirms SSH accessible from personal VLAN
3. `curl -k https://10.0.69.100:6443` — confirms VIP reachable after full cluster deploy
4. `nix flake check` — confirm config builds clean
