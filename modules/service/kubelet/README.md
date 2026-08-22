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
