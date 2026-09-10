# ha-cluster

A five-machine HA Kubernetes cluster (three control-plane, two workers, one floating VIP) declared through cairn's `cairn.clusters` flake-module interface.

- [`cluster.nix`](./cluster.nix) — the whole cluster in one attrset: machines, their roles and IPs, and the services that deviate from the defaults.
- [`flake.nix`](./flake.nix) — imports `cairn.flakeModules.default` and assigns the spec to `cairn.clusters.example`.

Everything not mentioned in `cluster.nix` comes from the defaults: pki, etcd, apiserver, kubelet, network, kubeconfig, inoculant and coredns are all deployed, each to the machines its role implies.

See [`docs/USAGE.md`](../../docs/USAGE.md) for a walkthrough of this topology, the full option surface, and the `clan` commands that deploy it.

For the lower-level path, a cluster whose `inventory.instances` are written out by hand with `cairn.clusters` left unset, see [`examples/single-node`](../single-node).
