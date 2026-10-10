# kubeconfig

Installs an admin kubeconfig at `/etc/kubernetes/admin.kubeconfig` and
`kubectl` on the machine. Generates the `admin-cert` via [pki](../pki),
which must be assigned to the same machine.

The kubectl comes from the cluster's pinned Kubernetes minor
(`version.nix`), keeping it within Kubernetes' one-minor kubectl skew. A
cluster that pins no minor follows nixpkgs' `pkgs.kubectl`, and
`cluster.cairn.kubeconfig.kubectl` overrides either.

`kubectl` works with no setup for root and for members of
`cluster.cairn.adminGroup` (`wheel` by default), who can read the kubeconfig
and the admin key. It is wrapped to default `KUBECONFIG` to the admin
kubeconfig, since `sudo` resets the variable the service also exports to
login shells; a `KUBECONFIG` already set wins. Set `adminGroup = null` to keep
both readable by root alone.

The [coredns](../coredns) and [flux](../flux) services (via
[inoculant](../inoculant)) reuse this service's `admin-cert` for cluster
bootstrap RBAC — assign `kubeconfig` to any machine that also runs those.
