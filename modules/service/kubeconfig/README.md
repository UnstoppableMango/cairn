# kubeconfig

Installs an admin kubeconfig at `/etc/kubernetes/admin.kubeconfig` and
`kubectl` on the machine. Generates the `admin-cert` via [pki](../pki),
which must be assigned to the same machine.

The kubectl comes from the cluster's pinned Kubernetes minor
(`version.nix`), keeping it within Kubernetes' one-minor kubectl skew. A
cluster that pins no minor follows nixpkgs' `pkgs.kubectl`, and
`cluster.cairn.kubeconfig.kubectl` overrides either.

The [coredns](../coredns) and [flux](../flux) services (via
[inoculant](../inoculant)) reuse this service's `admin-cert` for cluster
bootstrap RBAC — assign `kubeconfig` to any machine that also runs those.
