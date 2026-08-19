# rosequartz — NixOS Kubernetes Service Module

Multi-master HA Kubernetes cluster clan service. Targets Raspberry Pi 4B control-plane nodes (`pik8s4–6`) and an x86_64 worker (`agreus`).

## Architecture

```
           VIP: 192.168.1.100:6443
                    │
          ┌─────────▼──────────┐
          │    keepalived       │  VRRP — one node holds VIP
          │    HAProxy :6443    │  → apiserverPort (6444)
          └─────────┬──────────┘
          ┌─────────┼─────────┐
       pik8s4    pik8s5    pik8s6
     apiserver  apiserver  apiserver
       etcd      etcd      etcd
         └────── etcd cluster ──────┘
                    │
                worker (agreus)
                  kubelet
```

- **keepalived** — VRRP virtual IP; all control-plane nodes run in BACKUP state, highest priority wins
- **HAProxy** — binds VIP `:6443`, round-robins to local apiservers on `:6444` (so firewall can distinguish internal vs external)
- **etcd** — 3-node TLS-authenticated cluster; mTLS between peers and clients

## Files

| File | Purpose |
|------|---------|
| `default.nix` | Clan service definition; `control-plane` and `worker` roles |
| `control-plane.nix` | Full NixOS config for master nodes (apiserver, etcd, keepalived, HAProxy) |
| `worker.nix` | NixOS config for worker nodes (kubelet only) |
| `pki.nix` | cfssl-based PKI machinery; `cluster.rosequartz.pki.*` options |
| `network.nix` | Flannel CNI setup |
| `flux.nix` | Optional coredns + Flux bootstrap via `inputs.inoculant` (`cluster.rosequartz.fluxBootstrap.enable`) |

## NixOS services.kubernetes Options

`services.kubernetes` is the NixOS wrapper for kube components. Rosequartz uses `easyCerts = false` throughout — all certs are managed by `pki.nix` via clan vars.

### Key options used

```nix
services.kubernetes = {
  roles = [ "master" ];     # enables apiserver, controller-manager, scheduler, kubelet
  # roles = [ "node" ];     # worker: enables kubelet only

  masterAddress = cfg.vip;          # advertised kube master address (VIP)
  apiserverAddress = "https://${cfg.vip}:6443";
  easyCerts = false;                # disable auto cert generation — we supply all certs
  caFile = cfg.pki.ca.cert;        # cluster-wide CA

  apiserver = {
    advertiseAddress = cfg.advertiseAddress;   # node-local IP
    securePort = cfg.apiserverPort;            # 6444 (HAProxy fronts 6443)
    clientCaFile = ...;
    tlsCertFile = ...;
    tlsKeyFile = ...;
    serviceAccountKeyFile = ...;
    serviceAccountSigningKeyFile = ...;
    kubeletClientCertFile = ...;               # apiserver→kubelet mTLS
    kubeletClientKeyFile = ...;
    etcd.servers = etcdClientEndpoints;        # https://<ip>:2379 for each node
    etcd.caFile = ...;
    etcd.certFile = ...;                       # etcd client cert for apiserver
    etcd.keyFile = ...;
  };

  controllerManager.serviceAccountKeyFile = ...;
  controllerManager.kubeconfig.certFile = ...;
  controllerManager.kubeconfig.keyFile = ...;

  scheduler.kubeconfig.certFile = ...;
  scheduler.kubeconfig.keyFile = ...;

  kubelet = {
    clientCaFile = ...;         # verifies kubelet client certs
    tlsCertFile = ...;          # kubelet server cert (SAN = node IP)
    tlsKeyFile = ...;
    kubeconfig.certFile = ...;  # kubelet→apiserver client cert
    kubeconfig.keyFile = ...;
  };

  flannel.enable = lib.mkForce false;  # disable built-in flannel; use services.flannel directly
};
```

### services.etcd

External etcd cluster managed separately from Kubernetes:

```nix
services.etcd = {
  name = localNode.name;                    # hostname for cluster membership
  listenClientUrls = [ "https://0.0.0.0:2379" ];
  listenPeerUrls = [ "https://0.0.0.0:2380" ];
  advertiseClientUrls = [ "https://<node-ip>:2379" ];
  initialAdvertisePeerUrls = [ "https://<node-ip>:2380" ];
  initialCluster = [ "<name>=https://<ip>:2380" ... ];  # all nodes
  initialClusterState = "new";  # "existing" when replacing a member

  # mTLS — both client and peer auth required
  clientCertAuth = true;
  peerClientCertAuth = true;
  trustedCaFile = cfg.pki.ca.cert;
  certFile = ...;             # etcd-server-cert (peer profile)
  keyFile = ...;
  peerCertFile = ...;         # etcd-peer-cert (peer profile)
  peerKeyFile = ...;
  peerTrustedCaFile = cfg.pki.ca.cert;
};
```

## PKI (pki.nix)

Wraps clan vars to produce cfssl-signed certificates. All certs derive from a single CA injected via `clan vars generate` prompts.

### CA flow
1. `clan vars generate` prompts for `ca-crt` and `ca-key` (multiline/hidden)
2. CA material stored as clan vars (shared across all machines)
3. Each cert generator has `dependencies = [ "rosequartz-ca" ]`

### Cert definition pattern

```nix
cluster.rosequartz.pki.certs.<name> = {
  cn = "...";           # Certificate CN
  org = null;           # O field (organization), null if not needed
  hosts = [ ];          # SANs — cfssl auto-detects IP vs DNS
  profile = "server";   # "server" | "client" | "peer"
  owner = "kubernetes"; # OS user that owns the private key file
  share = true;         # true = shared across machines; false = per-machine
  # Outputs (read-only):
  cert = "...";         # path to .crt file (from clan vars)
  key = "...";          # path to .key file (from clan vars)
};
```

Shared certs (same keypair on all nodes): `sa`, `apiserver-cert`, `etcd-client-cert`, `admin-cert`, `controller-manager-cert`, `scheduler-cert`, `flannel-cert`.  
Per-machine certs (`share = false`): `etcd-server-cert`, `etcd-peer-cert`, `kubelet-cert`, `kubelet-client-cert`.

### cfssl profiles

| Profile | Key usages |
|---------|-----------|
| `server` | digital signature, server auth |
| `client` | digital signature, client auth |
| `peer` | digital signature, server auth, client auth |

## Network (network.nix)

Uses `services.flannel` directly (upstream `services.kubernetes.flannel` is disabled):

```nix
services.flannel = {
  enable = true;
  storageBackend = "kubernetes";  # reads network config from kube API
  network = config.services.kubernetes.clusterCidr;
  kubeconfig = flannelKubeconfig;  # static file with flannel client cert
};
```

CNI config in kubelet hardcodes bridge/flannel. `networking.dhcpcd.denyInterfaces` blocks DHCP on `cni0*` and `flannel*`.

Firewall ports opened by control-plane:

| Port | Service |
|------|---------|
| 6443 | HAProxy (external VIP) |
| 6444 | kube-apiserver (internal) |
| 2379 | etcd client |
| 2380 | etcd peer |
| 10250 | kubelet API |
| 10257 | controller-manager |
| 10259 | scheduler |

Worker opens only 10250. Flannel needs UDP 8285 (udp backend) and 8472 (VXLAN).

Required kernel config:

```nix
boot.kernelModules = [ "br_netfilter" ];
boot.kernel.sysctl = {
  "net.bridge.bridge-nf-call-iptables" = 1;
  "net.bridge.bridge-nf-call-ip6tables" = 1;
  "net.ipv4.ip_forward" = 1;
};
```

## Clan Service Registration

In `clan.nix`:

```nix
modules."@UnstoppableMango/rosequartz" = import ./modules/service/rosequartz;

inventory.instances.rosequartz = {
  module.name = "@UnstoppableMango/rosequartz";
  module.input = "self";

  roles.control-plane = {
    settings = { vip = "192.168.1.100"; clusterName = "rosequartz"; };
    machines.pik8s4.settings.ip = "192.168.1.104";
    machines.pik8s5.settings.ip = "192.168.1.105";
    machines.pik8s6.settings.ip = "192.168.1.106";
  };

  roles.worker = {
    settings = { vip = "192.168.1.100"; clusterName = "rosequartz"; };
    machines.agreus.settings.ip = "192.168.1.187";
  };
};
```

Machines get the `"rosequartz"` tag via `inventory.machines.<name>.tags`.

## Cluster Options Reference

All under `cluster.rosequartz.*` (set in the `nixosModule` by the clan service):

| Option | Default | Notes |
|--------|---------|-------|
| `nodes` | (required) | List of `{name, ip}` for all control-plane nodes |
| `vip` | (required) | Keepalived floating IP |
| `clusterName` | (required) | Used in TLS SANs and kubeconfig |
| `advertiseAddress` | (required) | This node's IP |
| `apiserverPort` | `6444` | Internal port; HAProxy fronts it at 6443 |
| `interface` | (required) | NIC for keepalived VRRP |
| `virtualRouterId` | `50` | VRRP ID (1–255, unique per subnet) |
| `keepalivedPriority` | `100` | Highest wins VIP |
| `serviceClusterIP` | `10.0.0.1` | First service CIDR IP; added to apiserver SANs |
| `pki.certValidityDays` | `3650` | ~10 years |
| `etcd.initialClusterState` | `"new"` | Set to `"existing"` when replacing etcd member |

## Gotchas

- `apiserverPort = 6444` is intentional — HAProxy owns 6443, so apiserver binds to 6444. Both must be open in the firewall.
- `machineNodes` in `default.nix` collects all machines assigned to `roles.control-plane` to build the `nodes` list. Only control-plane machines appear in `nodes`, not workers.
- `localNode` in `control-plane.nix` is derived via `findFirst` matching `advertiseAddress`. If IP mismatches the node list, evaluation throws.
- `etcd.initialCluster` defaults to all nodes. Override when replacing a member (`initialClusterState = "existing"`).
- Keepalived `state = "BACKUP"` on all nodes — no `MASTER`; highest `priority` wins. Adjust `keepalivedPriority` per machine in inventory if needed.
- `flux.nix` bootstraps coredns + Flux via `inputs.inoculant`'s NixOS module. Inoculant's own cert generation relies on nixpkgs' certmgr/easyCerts flow, which rosequartz doesn't run — `flux.nix` force-overrides `services.kubernetes.pki.certs.inoculant` with a rosequartz-issued cert instead. CoreDNS manifests are harvested from `config.services.kubernetes.addonManager.{addons,bootstrapAddons}` (populated by nixpkgs' `addons.dns` module, which is mkDefault-enabled but never applied since `addonManager.enable = false`) rather than hand-written.
- Shared certs (`share = true`) are generated once and deployed to all machines. Per-machine certs (`share = false`) are generated separately per machine.
