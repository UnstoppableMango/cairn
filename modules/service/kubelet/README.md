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

## Pod capacity

`maxPods` (default `110`, kubelet's own) caps the pods the kubelet admits,
through `extraConfig.maxPods` in the KubeletConfiguration file rather than
the deprecated `--max-pods` flag.

The node's podCIDR is the ceiling. kube-controller-manager hands out a /24
per node by default, so 254 addresses, and pods admitted past that get no
IP. Widen `--node-cidr-mask-size` before raising `maxPods` above it.

## Reservations

`systemReserved`, `kubeReserved` and `evictionHard` decide how much of a
machine the scheduler is allowed to hand out.

Allocatable is capacity minus all three, and the scheduler places against
allocatable, never capacity. All three default to empty, which leaves
kubelet's own behaviour and means a node advertises very nearly its whole
memory as schedulable.

That default suits a machine that only runs pods. It suits one badly when
something substantial runs outside Kubernetes on it: a storage daemon, a
build agent, a database. There the scheduler commits memory those processes
are already using, and the kernel OOM killer resolves the shortfall by
badness score rather than by what the node exists to do.

```nix
kubelet = {
  systemReserved = {
    cpu = "2";
    memory = "2Gi";
  };
  kubeReserved = {
    cpu = "1";
    memory = "1Gi";
  };
  evictionHard."memory.available" = "1Gi";
};
```

Reserve for what runs outside Kubernetes, and no more. Over-reserving is
not free: the difference is capacity no pod can ever be given, and it does
not announce itself. `kubectl describe node` shows requests as a percentage
of allocatable, so a node reserving most of itself can read as nearly full
while most of the machine sits idle. Compare `.status.capacity` against
`.status.allocatable` to see it.

The `evictionHard` memory threshold reserves as well as triggers. It holds
back a margin the scheduler cannot promise away, which is what gives
eviction a chance to run before the kernel does.

Each key is omitted from the KubeletConfiguration when empty rather than
written as `{}`, so a consumer still setting one directly on
`services.kubernetes.kubelet.extraConfig` does not collide with this
module.

## Kubernetes version

The role accepts `kubernetesVersion`, a kubepkgs minor such as `"1.36"`.
It sets `services.kubernetes.package` to a join of kubepkgs' per-component
binaries for that minor, moving every Kubernetes component on the machine
together; the apiserver, controller-manager, scheduler and proxy all run
from the same package. `null` (the default) follows nixpkgs'
`pkgs.kubernetes`. The kubelet service carries this setting because it is
the one service assigned to every machine. See `docs/UPGRADES.md` for the
rolling-upgrade procedure built on it.
