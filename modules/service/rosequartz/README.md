# rosequartz

Clan service module for deploying a high-availability Kubernetes cluster on NixOS.

Combines `services.kubernetes` (apiserver, etcd, controller-manager, scheduler, kubelet), keepalived VRRP, and HAProxy to produce a multi-master cluster with a stable virtual IP. PKI is managed by cfssl through the clan vars system — no certificates are checked in.

## Roles

| Role | Description |
|------|-------------|
| `control-plane` | Runs apiserver, etcd, keepalived, and HAProxy. Multiple machines form an etcd quorum; one holds the VIP at any given time. |
| `worker` | Runs kubelet only and joins the cluster via the VIP. |

## How it works

Each control-plane machine runs:
- A local etcd member, forming a quorum with peer mTLS
- A local apiserver on a configurable internal port
- HAProxy, which listens on 6443 and load-balances to all local apiservers
- Keepalived, which elects one node to hold the virtual IP via VRRP

Clients connect to `vip:6443`. HAProxy distributes requests; if a node goes down, keepalived re-elects. Workers join by pointing at the same VIP.

Pod networking is provided by Flannel, using the Kubernetes API as its datastore backend.

## Key settings

These settings are configured per-role instance in `clan.nix`.

| Setting | Role | Description |
|---------|------|-------------|
| `ip` | both | Node IP address; used in etcd peer URLs and TLS SANs |
| `vip` | both | Virtual IP that HAProxy and keepalived share across control-plane nodes |
| `clusterName` | both | Included in TLS certificate subject names |

Additional options (interface, ports, VRRP priority, cert validity, etcd bootstrap state) have defaults suitable for most deployments and can be overridden in the NixOS module layer.

## Status

> **Work in progress.** Flux bootstrap is not yet complete. Options and cert structure may change.
