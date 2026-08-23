# coredns

Optional CoreDNS bootstrap via inoculant.
Manifests (ServiceAccount, `system:coredns` ClusterRole/ClusterRoleBinding, ConfigMap, Deployment, Service) are hand-authored in `./manifests.nix` rather than harvested from nixpkgs' `addonManager`/`addons.dns` modules, which cairn otherwise leaves disabled.
The CoreDNS container image is built directly from `pkgs.coredns` and seeded onto control-plane nodes; the Deployment is pinned to those nodes via node affinity and matching tolerations.

Requires [inoculant](../inoculant) and [kubeconfig](../kubeconfig) assigned
to the same machine.
