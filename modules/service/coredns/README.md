# coredns

Optional CoreDNS bootstrap via inoculant.
Manifests (ServiceAccount, `system:coredns` ClusterRole/ClusterRoleBinding, ConfigMap, Deployment, Service) are hand-authored in `./manifests.nix` rather than harvested from nixpkgs' `addonManager`/`addons.dns` modules, which cairn otherwise leaves disabled.
The CoreDNS container image is built directly from `pkgs.coredns` and seeded onto the assigned machines that run a kubelet; the Deployment is pinned to `nodeNames` via node affinity and matching tolerations.

`clusterIp` derives from `serviceClusterIpRange`, which defaults to nixpkgs' own apiserver default of `10.0.0.0/24`. Set it here alongside the apiserver's range rather than on its own; the machine bootstrapping the manifests need not be running an apiserver to read it from.

`nodeNames` defaults to the machines assigned this role, which is right while those machines are the ones running kubelets. Name the nodes outright when they are not.

Requires [inoculant](../inoculant) and [kubeconfig](../kubeconfig) assigned
to the same machine.
