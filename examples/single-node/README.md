# Minimal Single-Node Example

The smallest working cluster on cairn: one machine, `node1`, playing every role at once.
It runs `pki`, `etcd` (single member), `apiserver`, `kubelet`, `network` (flannel), and `kubeconfig`.
`loadbalancer`, `inoculant`, `coredns`, and `flux` are all skipped, they're optional; see `docs/USAGE.md` in the repo root for a full HA topology that adds them back.

## Two things that only matter because this is single-node

There's no loadbalancer, so `apiserver`'s `vip` is set to `node1`'s own IP and `apiserverPort` is forced to `6443` (normally the loadbalancer fronts `6443` and the real apiserver binds `6444`).
If you grow this into multiple control-plane machines, drop `apiserverPort = 6443` from `inventory.nix` and add a `loadbalancer` instance instead, following `docs/USAGE.md`.

A control-plane-only node is unschedulable by default in nixpkgs' `services.kubernetes` module (it gets a `NoSchedule` taint and `kubelet.unschedulable = true`).
`flake.nix` works around this with `clan.machines.node1.services.kubernetes.roles = [ "node" ];`, so `node1` can actually run pods.
On a real multi-machine cluster, dedicated worker machines don't need this since they pick up the `kubelet.worker` role instead.

## Adapting this for a real machine

- Substitute `node1`'s IP (`10.10.0.11` by default, passed via `inventory.nix`'s `ip`/`vip` arguments) for a real one on your network.
- `cairn.url = "path:../.."` points at this repo's checkout so the example is self-contained; point it at `github:UnstoppableMango/cairn` (or a pinned rev) for a real deployment.
- Run `nix flake check` then `clan vars generate`, this prompts for CA certificate/key material (PEM) on first run.
  If you already have CA material to reuse, set `cluster.cairn.pki.ca.override = { crt; key; }` instead; see `modules/service/pki/README.md`.
- `clan machines install node1 --target-host root@<ip>` to deploy, then `ssh root@<ip>` and `kubectl get nodes` to verify.
