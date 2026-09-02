# kubelet

Configures `services.kubernetes.kubelet.*`.

One `node` role, for every machine that should appear as a Kubernetes node,
whether or not an apiserver runs alongside. Every kubelet reaches the
apiserver through the VIP, so the role takes the same settings everywhere.

`schedulable` (default `true`) decides whether the machine gets the NixOS
`node` role and so accepts pods. Set it false where an apiserver runs:
`services.kubernetes.roles = [ "master" ]` already enables the kubelet
there, and nixpkgs taints a master-only machine unschedulable, which adding
`node` would undo.

Also wires `services.kubernetes.proxy.kubeconfig` (kube-proxy is enabled by
default on both the `master` and `node` NixOS kubernetes roles), using the
`kube-proxy-cert` defined by [network](../network).

Needs [pki](../pki) and [network](../network) assigned to the same
machines.

## Kubernetes version

The role accepts `kubernetesVersion`, a kubepkgs minor such as `"1.36"`.
It sets `services.kubernetes.package` to a join of kubepkgs' per-component
binaries for that minor, moving every Kubernetes component on the machine
together; the apiserver, controller-manager, scheduler and proxy all run
from the same package. `null` (the default) follows nixpkgs'
`pkgs.kubernetes`. The kubelet service carries this setting because it is
the one service assigned to every machine. See `docs/UPGRADES.md` for the
rolling-upgrade procedure built on it.
