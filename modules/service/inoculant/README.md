# inoculant

Imports `inputs.inoculant`'s NixOS module and points its `clusterAdmin` cert
at the [kubeconfig](../kubeconfig) service's `admin-cert`, rather than
minting a dedicated one — inoculant's own cert-generation path relies on
nixpkgs' certmgr/easyCerts flow, which cairn doesn't run.

Shared by [coredns](../coredns) and [flux](../flux); assign this service
(and `kubeconfig`) to any machine that runs either of them.

## Node labels

The `node` role takes a `nodeLabels` setting, forwarded to inoculant's
`services.kubernetes.inoculant.nodeLabels`:

```nix
roles.node.machines.node1.settings.nodeLabels = {
  "node-role.kubernetes.io/control-plane" = "";
};
```

kubelet may not assign itself `node-role.kubernetes.io/*` labels (the
NodeRestriction admission plugin rejects them), so inoculant applies them
from a `label-node` container instead, using the scoped token its bootstrap
container mints. The `v1/Node` permission that needs is derived
automatically from a non-empty `nodeLabels`.

Setting `nodeLabels` enables inoculant on the machine by itself, so this
service is worth assigning even on nodes running neither coredns nor flux.
Labels are `types.attrsOf str`, so role-wide `roles.node.settings.nodeLabels`
and per-machine `roles.node.machines.<name>.settings.nodeLabels` merge.
