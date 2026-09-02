# kubelet

Configures `services.kubernetes.kubelet.*`.

- `control-plane` role: applied alongside the [apiserver](../apiserver)
  service on master nodes. `services.kubernetes.roles = [ "master" ]` (set
  by apiserver) already enables kubelet on these nodes; this role only
  supplies kubelet's own certs and options.
- `worker` role: node-only machines. Sets
  `services.kubernetes.roles = [ "node" ]` itself, since no apiserver
  service runs there.

Also wires `services.kubernetes.proxy.kubeconfig` (kube-proxy is enabled by
default on both the `master` and `node` NixOS kubernetes roles), using the
`kube-proxy-cert` defined by [network](../network).

Needs [pki](../pki) and [network](../network) assigned to the same
machines.

## Kubernetes version

Both roles accept `kubernetesVersion`, a kubepkgs minor such as `"1.36"`.
It sets `services.kubernetes.package` to a join of kubepkgs' per-component
binaries for that minor, moving every Kubernetes component on the machine
together; the apiserver, controller-manager, scheduler and proxy all run
from the same package. `null` (the default) follows nixpkgs'
`pkgs.kubernetes`. The kubelet service carries this setting because it is
the one service assigned to every machine. See `docs/UPGRADES.md` for the
rolling-upgrade procedure built on it.
