# kubelet

Configures `services.kubernetes.kubelet.*`.

- `control-plane` role: applied alongside the [apiserver](../apiserver)
  service on master nodes. `services.kubernetes.roles = [ "master" ]` (set
  by apiserver) already enables kubelet on these nodes; this role only
  supplies kubelet's own certs and options.
- `worker` role: node-only machines. Sets
  `services.kubernetes.roles = [ "node" ]` itself, since no apiserver
  service runs there.

Needs [pki](../pki) assigned to the same machines.
