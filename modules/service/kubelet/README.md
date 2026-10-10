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

## Runtime handlers

`containerdRuntimes` adds containerd CRI runtime handlers beside nixpkgs' default `runc`, each one a `handler` a Kubernetes RuntimeClass can name.
The cluster option `services.kubelet.containerdRuntimes` applies to every kubelet machine, so a RuntimeClass using one needs no `scheduling` section.

Each value is written as-is under `plugins."io.containerd.grpc.v1.cri".containerd.runtimes.<name>`, the `version = 2` layout nixpkgs' kubernetes module writes.
A handler inherits nothing from `runc`, so set `runtime_type`, and `options.SystemdCgroup = true` to match the kubelet's cgroup driver.

```nix
kubelet.containerdRuntimes.runc-cgroup-writable = {
  runtime_type = "io.containerd.runc.v2";
  cgroup_writable = true;
  options.SystemdCgroup = true;
};
```

`cgroup_writable` (containerd 2.1+) mounts `/sys/fs/cgroup` read-write in unprivileged containers.
A pod that runs its own container runtime (dind, podman, buildkitd) needs that to create cgroups.
Pair it with `hostUsers: false`, so runc delegates the pod's cgroup to the user namespace's root.
Without a user namespace, root in the pod is root on the node.

## Nix store images

`nixSnapshotter` (default `false`) runs [nix-snapshotter](https://github.com/pdtpartners/nix-snapshotter) as the node's containerd snapshotter and the kubelet's image service.
A pod can then name an image as `nix:0/nix/store/...`, and its store paths come straight from the node's nix store instead of being pulled and unpacked.
Registry images keep working through nix-snapshotter's embedded overlay snapshotter.

The cluster option `services.kubelet.nixSnapshotter` sets it for every kubelet machine, and `machines.<name>.nixSnapshotter` overrides it for one.
Switching a node discards the images and container snapshots containerd holds under its old snapshotter, so drain each node before switching it.

Two things a workload needs, both covered by the `nix-snapshotter` VM test:

- In a `hostUsers: false` pod, every volume's mount point has to exist in the image.
  The root filesystem belongs to the host's root there, so runc cannot create a missing one.
- An idmapped hostPath mount of the node's `/nix/store`, for builds through the node's daemon, needs a filesystem that supports idmapping, such as ext4.
  virtiofs does not.

The module declares the `remap-ids` capability on containerd's `nix` proxy plugin, which nix-snapshotter does not advertise itself.
Without it, containerd chowns the whole snapshot for a user-namespaced pod, which fails on the read-only store bind mounts.

## Kubernetes version

The role accepts `kubernetesVersion`, a kubepkgs minor such as `"1.36"`.
It sets `services.kubernetes.package` to kubepkgs' combined `kubernetes`
package for that minor, pause shim included, moving every Kubernetes component on the machine
together; the apiserver, controller-manager, scheduler and proxy all run
from the same package. `null` (the default) follows nixpkgs'
`pkgs.kubernetes`. The kubelet service carries this setting because it is
the one service assigned to every machine. See `docs/UPGRADES.md` for the
rolling-upgrade procedure built on it.
