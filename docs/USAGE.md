# Usage: Deploying a Full Cluster

This walks through deploying a complete HA Kubernetes cluster with cairn, end to end.

Cairn itself is a library flake.
It registers [clan](https://clan.lol) service modules (`@UnstoppableMango/pki`, `@UnstoppableMango/etcd`, and so on) but declares no machines and no inventory of its own; see `clan.nix` in the repo root.
Deploying a cluster means creating your own flake that adds cairn as an input and describes the cluster you want.

There are two ways to write that description, and this document covers both:

- **`cairn.clusters.<name>`**, the flake-module interface, where the whole cluster is one attrset and cairn generates the inventory for you.
  Start here.
- **A hand-written `inventory.instances`**, one block per service.
  Everything the option tree does, it does by generating exactly this, so the lower level stays available and the two can be mixed.
  See [Writing the Inventory by Hand](#writing-the-inventory-by-hand).

## Example Topology

The walkthrough below builds a 5-machine cluster:

| Machine | Role | IP |
| --------- | ------------- | ----------- |
| `cp1` | control-plane | 10.10.0.11 |
| `cp2` | control-plane | 10.10.0.12 |
| `cp3` | control-plane | 10.10.0.13 |
| `worker1` | worker | 10.10.0.21 |
| `worker2` | worker | 10.10.0.22 |

The three control-plane machines form the etcd quorum and share a floating VIP, `10.10.0.10`.
The cluster is named `example`.
Substitute your own machine names, IPs, and cluster name throughout.

A runnable copy of everything below lives in [`examples/ha-cluster`](../examples/ha-cluster).

## Prerequisites

- Nix with flakes enabled.
- The `clan` CLI, from [clan-core](https://git.clan.lol/clan/clan-core) 26.05 (the same version cairn's `flake.nix` pins).
- Five machines already running a minimal NixOS install, reachable over SSH, each on the same L2 subnet (the VIP is managed via keepalived VRRP, which needs L2 adjacency).

## Scaffold a Consumer Flake

Create a new repo for your cluster and add cairn as a flake input.
Cairn exposes a `flake.flakeModules.default` flake-parts module that wires in clan-core for you, so you don't need to declare `clan-core` as a separate input or import its flake module yourself:

```nix
# flake.nix
{
  description = "example k8s cluster on cairn";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";
    cairn.url = "github:UnstoppableMango/cairn";
  };

  outputs =
    inputs@{ flake-parts, cairn, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      imports = [ cairn.flakeModules.default ];

      # The attribute name is the Kubernetes cluster name.
      cairn.clusters.example = import ./cluster.nix;
    };
}
```

`cairn.flakeModules.default` also sets a sensible default `systems` list; override it yourself if you need something different.

Note that `clan-core` is not required as a top-level input here for the flake to evaluate or for `clan` CLI commands like `machines list`/`install`/`update` to work.
The one exception is the `clan --template clan-core#<name>` shorthand (e.g. `clan flakes create --template clan-core#new-machine`), which resolves against a literal `clan-core` input; add it as its own input yourself if you rely on that shorthand.

## Declare the Cluster

Put the cluster in its own file, `cluster.nix`, assigned to `cairn.clusters.example` above.

### Machines

Every machine gets a `role` and an `ip`.
The role decides which services the machine is assigned by default, what tag it carries in the inventory, and what `node-role.kubernetes.io/*` label it gets:

```nix
# cluster.nix
{
  vip = "10.10.0.10";

  machines = {
    cp1 = { role = "control-plane"; ip = "10.10.0.11"; };
    cp2 = { role = "control-plane"; ip = "10.10.0.12"; };
    cp3 = { role = "control-plane"; ip = "10.10.0.13"; };
    worker1 = { role = "worker"; ip = "10.10.0.21"; };
    worker2 = { role = "worker"; ip = "10.10.0.22"; };
  };
}
```

`vip` is where nodes and clients reach the apiserver.
With the loadbalancer enabled (below) it is the floating address keepalived manages; without one, point it at your single apiserver machine's own IP.

That is already a working cluster.
Everything else is deployed on defaults: `pki`, `network`, `kubeconfig` and `inoculant` on every machine, `etcd`, `apiserver` and `coredns` on the control-plane machines, and `kubelet` on all of them in the role their machine implies.

### Services

Each service is configured under `services.<name>`, and each has an `enable`, a machine list, and its own options.
Two services are off by default.

**loadbalancer** is what makes the control plane highly available: keepalived floats the VIP across the control-plane machines and HAProxy fans out to the apiservers behind it.
Enabling it also moves the apiservers themselves to port 6444, leaving 6443 on the VIP to HAProxy:

```nix
services.loadbalancer = {
  enable = true;
  interface = "eth0";
  # Only needs changing if another VRRP-managed VIP shares the subnet.
  virtualRouterId = 51;
};
```

Stagger the VRRP priorities on the machines themselves, so one of them holds the VIP by default:

```nix
machines.cp1 = { role = "control-plane"; ip = "10.10.0.11"; keepalivedPriority = 150; };
machines.cp2 = { role = "control-plane"; ip = "10.10.0.12"; keepalivedPriority = 100; };
machines.cp3 = { role = "control-plane"; ip = "10.10.0.13"; keepalivedPriority = 50; };
```

**flux** bootstraps GitOps against your own manifests repo.
Leave it disabled if you don't want that:

```nix
services.flux = {
  enable = true;
  url = "https://github.com/your-org/example-cluster";
  branch = "main";
  path = "./clusters/example";
};
```

The rest of the surface, all optional:

| Option | Default | What it does |
| --- | --- | --- |
| `apiServerPort` | `6443` | Port the apiserver is reached on at the VIP |
| `services.apiserver.port` | `6444` with a loadbalancer, else `apiServerPort` | Port each apiserver actually binds |
| `services.apiserver.serviceClusterIP` | `10.0.0.1` | First IP of the service CIDR, included in the apiserver's certificate SANs |
| `services.pki.generatorPrefix` | `cairn` | Prefix for clan var generator names |
| `services.pki.certValidityDays` | `3650` | Validity period for generated certificates |
| `services.pki.ca.override` | `null` | Bring-your-own CA material, see [Generate Secrets](#generate-secrets) |
| `services.pki.certs` | `{}` | Additional certificates for your own workloads |
| `services.etcd.initialClusterState` | `"new"` | Set to `"existing"` when replacing a member or restoring into a live cluster |
| `services.coredns.{clusterIp,clusterDomain,replicas,corefile,image}` | derived | CoreDNS tuning |
| `services.<name>.machines` | from each machine's `role` | Which machines run this service |
| `services.<name>.settings` | `{}` | Raw inventory settings merged over the generated ones |
| `services.<name>.extraModules` | `[]` | Extra NixOS modules for this service's role assignments |

`kubelet` is the one service with two machine lists, `controlPlaneMachines` and `workerMachines`, since its two roles take different settings.

### Machine configuration

Each machine's own NixOS configuration (hardware, filesystems, bootloader) goes in `machines.<name>.nixos`, and anything common to the whole cluster in the cluster's own `nixos`:

```nix
machines.cp1 = {
  role = "control-plane";
  ip = "10.10.0.11";
  nixos = ./hardware/cp1.nix;
};

# Merged into every machine in the cluster.
nixos = {
  nixpkgs.hostPlatform = "x86_64-linux";
};
```

One machine option is worth knowing about for small clusters: `schedulable`.
A control-plane-only machine is tainted unschedulable by nixpkgs' kubernetes module, so a cluster with no separate worker machines needs `schedulable = true` on its control-plane machines before pods will land anywhere.

### Escape hatches

Nothing here is a ceiling.
`services.<name>.settings` sets any inventory setting this module doesn't model yet, and wins over the generated ones.
`extraInstances` splices raw `inventory.instances` entries in alongside the generated ones, for services cairn doesn't ship at all.
And `clan` remains a normal flake-parts option, so anything else clan accepts can be written next to `cairn.clusters`.

## Generate Secrets

Before deploying, check the flake evaluates and generate the cluster's vars (secrets and certs):

```sh
nix flake check
clan vars generate
```

The `pki` service's CA generator prompts for a CA certificate and private key (PEM, pasted multi-line) the first time it runs, then signs every other certificate in the cluster against it.
If you already have CA material you want to reuse, for example when migrating an existing cluster's PKI trust onto cairn, set `services.pki.ca.override` instead and it copies that material in without prompting:

```nix
services.pki.ca.override = {
  crt = "/path/to/ca.crt";
  key = "/path/to/ca.key";
};
```

Paths are resolved at `clan vars generate` time on the invoking machine and never enter the Nix store.
The same `override` exists per-certificate, via `services.pki.certs.<name>.override`.

If instead you already have generated vars for a pre-existing cluster and just want cairn's generators to line up with the names already on disk, rather than bringing in raw PEM files, set `services.pki.generatorPrefix` to match.
It defaults to `"cairn"`, it is cluster-wide (every machine's generators must agree or certs stop resolving), and it only needs to change when migrating pre-existing generator names.

## Bootstrap the Machines

The exact `clan` CLI flags can drift between clan-core releases, so treat this section as illustrative and check `clan machines --help` against your pinned `clan-core` version.

Install the three control-plane machines first, since etcd's `initialClusterState` defaults to `"new"` and expects the full quorum to come up together:

```sh
clan machines install cp1 --target-host root@10.10.0.11
clan machines install cp2 --target-host root@10.10.0.12
clan machines install cp3 --target-host root@10.10.0.13
```

Once the VIP is answering on `10.10.0.10:6443`, install the workers:

```sh
clan machines install worker1 --target-host root@10.10.0.21
clan machines install worker2 --target-host root@10.10.0.22
```

For subsequent changes, redeploy an already-installed machine with:

```sh
clan machines update cp1
```

## Verify

SSH into any machine that has the `kubeconfig` service (all five, by default) and run `kubectl`.
The service already sets `KUBECONFIG` and installs `kubectl`:

```sh
ssh root@10.10.0.11
kubectl get nodes
kubectl get pods -A
```

You should see all five nodes `Ready`, with `cp1`/`cp2`/`cp3` holding the etcd quorum and the VIP.

## Writing the Inventory by Hand

`cairn.clusters` generates clan inventory instances; you can also write them yourself.
Do that when you want per-instance control the option tree doesn't expose, or when you're wiring cairn's services into an inventory that already exists.

The flake module is the same one either way; just leave `cairn.clusters` unset and write `clan` yourself.
An empty option tree produces no inventory, so the two don't collide, and a cluster declared through `cairn.clusters` can sit alongside hand-written instances in the same flake:

```nix
imports = [ cairn.flakeModules.default ];

clan = {
  imports = [ (import ./inventory.nix { cairnLib = cairn.lib; }) ];
};
```

Every `inventory.instances.<name>.module.input` you write against cairn's modules must be `"cairn"`, the name given to the flake input.
This is different from cairn's own internal examples (`modules/service/AGENTS.md`), which use `module.input = "self"` because those examples live inside cairn's own flake.

Start with the machines and their tags:

```nix
# inventory.nix
{ cairnLib }:
{
  inventory.machines = {
    cp1 = { tags = [ "control-plane" ]; };
    cp2 = { tags = [ "control-plane" ]; };
    cp3 = { tags = [ "control-plane" ]; };
    worker1 = { tags = [ "worker" ]; };
    worker2 = { tags = [ "worker" ]; };
  };

  inventory.instances = {
    # instances go here, one per service, see below
  };
}
```

Now register a service instance for each cairn module.
The order below follows each service's own dependency on the others; within the file the order doesn't matter, `clan` resolves it.

Note that settings can only hang off `roles.<role>.settings` (role-wide) or `roles.<role>.machines.<name>.settings` (per machine).
`tags` is membership-only: clan never reads settings nested under a tag.

### pki

Every machine that touches a certificate, directly or indirectly, needs the `node` role.
That's all five machines here, so use the built-in `all` tag:

```nix
inventory.instances.pki = {
  module.name = "@UnstoppableMango/pki";
  module.input = "cairn";

  roles.node.tags.all = { };
};
```

### etcd

Only the three control-plane machines are etcd members, and each needs its own IP, so assign them explicitly by machine instead of by tag.
`cairnLib.inventory.mkMachines common perMachine` merges settings shared across machines (`common`) with each machine's own overrides (`perMachine`), producing the `roles.<role>.machines.<name> = { settings = ...; }` shape clan expects:

```nix
inventory.instances.etcd = {
  module.name = "@UnstoppableMango/etcd";
  module.input = "cairn";

  roles.member.machines = cairnLib.inventory.mkMachines { clusterName = "example"; } {
    cp1.ip = "10.10.0.11";
    cp2.ip = "10.10.0.12";
    cp3.ip = "10.10.0.13";
  };
};
```

### apiserver

Same shape as etcd: one entry per control-plane machine, each with its own IP.
`apiserverPort` and `serviceClusterIP` are left at their defaults (`6444` and `10.0.0.1`).

```nix
inventory.instances.apiserver = {
  module.name = "@UnstoppableMango/apiserver";
  module.input = "cairn";

  roles.control-plane.machines = cairnLib.inventory.mkMachines { vip = "10.10.0.10"; clusterName = "example"; } {
    cp1.ip = "10.10.0.11";
    cp2.ip = "10.10.0.12";
    cp3.ip = "10.10.0.13";
  };
};
```

### kubelet

Control-plane machines only need their own IP (kubelet rides alongside the apiserver's own `master` role).
Worker machines need IP, VIP, and cluster name, since they have no apiserver service to pick those up from.

```nix
inventory.instances.kubelet = {
  module.name = "@UnstoppableMango/kubelet";
  module.input = "cairn";

  roles.control-plane.machines = cairnLib.inventory.mkMachines { } {
    cp1.ip = "10.10.0.11";
    cp2.ip = "10.10.0.12";
    cp3.ip = "10.10.0.13";
  };

  roles.worker.machines = cairnLib.inventory.mkMachines { vip = "10.10.0.10"; clusterName = "example"; } {
    worker1.ip = "10.10.0.21";
    worker2.ip = "10.10.0.22";
  };
};
```

### loadbalancer

Runs on the three control-plane machines, fronting the apiserver cluster at the VIP.
`keepalivedPriority` is staggered so `cp1` wins the VIP by default; any of the three can hold it if `cp1` goes down.
`virtualRouterId` must be unique on the subnet if you're running more than one VRRP-managed VIP nearby.

```nix
inventory.instances.loadbalancer = {
  module.name = "@UnstoppableMango/loadbalancer";
  module.input = "cairn";

  roles.control-plane.machines =
    cairnLib.inventory.mkMachines { vip = "10.10.0.10"; interface = "eth0"; virtualRouterId = 51; }
      {
        cp1.keepalivedPriority = 150;
        cp2.keepalivedPriority = 100;
        cp3.keepalivedPriority = 50;
      };
};
```

### network and kubeconfig

Both need only `vip` and `clusterName`, the same values on every machine, so a role-wide `settings` alongside the `all` tag works here.

```nix
inventory.instances.network = {
  module.name = "@UnstoppableMango/network";
  module.input = "cairn";

  roles.node.tags = [ "all" ];
  roles.node.settings = { vip = "10.10.0.10"; clusterName = "example"; };
};

inventory.instances.kubeconfig = {
  module.name = "@UnstoppableMango/kubeconfig";
  module.input = "cairn";

  roles.node.tags = [ "all" ];
  roles.node.settings = { vip = "10.10.0.10"; clusterName = "example"; };
};
```

### inoculant and coredns (optional)

`coredns` is only needed if you want cairn to bootstrap CoreDNS manifests for you.
It runs on the control-plane machines and reuses the `admin-cert` and kubeconfig from the `kubeconfig` service above, via `inoculant`.

`inoculant` is worth assigning more widely than that: its `nodeLabels` setting is how nodes get their `node-role.kubernetes.io/*` labels, which kubelet is forbidden from assigning itself.
Setting `nodeLabels` enables inoculant on that machine on its own, so the workers below get it too even though they run no CoreDNS.
Assign `kubeconfig` to every machine that gets `inoculant` (the `all` tag above already does).

```nix
inventory.instances.inoculant = {
  module.name = "@UnstoppableMango/inoculant";
  module.input = "cairn";

  roles.node.machines = cairnLib.inventory.mkMachines { } {
    cp1.nodeLabels = { "node-role.kubernetes.io/control-plane" = ""; };
    cp2.nodeLabels = { "node-role.kubernetes.io/control-plane" = ""; };
    cp3.nodeLabels = { "node-role.kubernetes.io/control-plane" = ""; };
    worker1.nodeLabels = { "node-role.kubernetes.io/worker" = ""; };
    worker2.nodeLabels = { "node-role.kubernetes.io/worker" = ""; };
  };
};

inventory.instances.coredns = {
  module.name = "@UnstoppableMango/coredns";
  module.input = "cairn";

  roles.control-plane.tags.control-plane = { };
};
```

### flux (optional)

`flux` bootstraps GitOps via inoculant, pointed at your own manifests repo rather than cairn's default.
Skip this instance if you don't want GitOps bootstrap.

```nix
inventory.instances.flux = {
  module.name = "@UnstoppableMango/flux";
  module.input = "cairn";

  roles.control-plane.tags.control-plane = {
    settings = {
      url = "https://github.com/your-org/example-cluster";
      branch = "main";
      path = "./clusters/example";
    };
  };
};
```

### NixOS-level options

A handful of cairn's options live only on the NixOS side, with no inventory setting behind them: `cluster.cairn.apiServerPort`, `cluster.cairn.etcd.initialClusterState`, the `cluster.cairn.coredns.*` knobs, and the `cluster.cairn.pki` `override` escape hatches.
Set those in `clan.machines.<name>`, on machines assigned a service that declares them.
`cairn.clusters` does exactly this for you.

## Where to Go From Here

- [`examples/ha-cluster`](../examples/ha-cluster) is this whole document as a runnable flake.
- [`examples/single-node`](../examples/single-node) is a minimal one-machine cluster with a hand-written inventory.
- [`docs/UPGRADES.md`](UPGRADES.md) is the design and runbook for upgrading a running cluster.
- Each service's own `README.md` under `modules/service/<name>/README.md` documents its options and dependencies in more depth.
- `modules/service/AGENTS.md` covers the clan service authoring model, useful if you want to add a new service to cairn itself.
