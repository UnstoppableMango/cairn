# Usage: Deploying a Full Cluster

This walks through deploying a complete HA Kubernetes cluster with cairn, end to end.

Cairn itself is a library flake.
It registers [clan](https://clan.lol) service modules (`@UnstoppableMango/pki`, `@UnstoppableMango/etcd`, and so on) but declares no machines and no inventory of its own; see `clan.nix` in the repo root.
Deploying a cluster means creating your own flake that adds cairn as an input and declares an `inventory` of machines and service instances against cairn's modules.
This is the same pattern the maintainer's own cluster repo, [the-cluster](https://github.com/UnstoppableMango/the-cluster), uses.

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

## Prerequisites

- Nix with flakes enabled.
- The `clan` CLI, from [clan-core](https://git.clan.lol/clan/clan-core) 26.05 (the same version cairn's `flake.nix` pins).
- Five machines already running a minimal NixOS install, reachable over SSH, each on the same L2 subnet (the VIP is managed via keepalived VRRP, which needs L2 adjacency).

## Scaffold a Consumer Flake

Create a new repo for your cluster and add cairn plus `clan-core` as flake inputs.

```nix
# flake.nix
{
  description = "example k8s cluster on cairn";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";
    cairn.url = "github:UnstoppableMango/cairn";
    clan-core = {
      url = "https://git.clan.lol/clan/clan-core/archive/26.05.tar.gz";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    inputs@{ flake-parts, clan-core, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [ "x86_64-linux" "aarch64-linux" ];
      imports = [ clan-core.flakeModules.default ];

      clan = {
        specialArgs = { inherit inputs; };
        imports = [ ./inventory.nix ];
      };
    };
}
```

Every `inventory.instances.<name>.module.input` you write against cairn's modules must be `"cairn"`, the name given to the flake input above.
This is different from cairn's own internal examples (`modules/service/AGENTS.md`), which use `module.input = "self"` because those examples live inside cairn's own flake.

## Declare the Inventory

Put the inventory in its own file, `inventory.nix`, imported by the `clan` block above.
Start with the machines and their tags:

```nix
# inventory.nix
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

Only the three control-plane machines are etcd members, and each needs its own IP, so assign them explicitly by machine instead of by tag:

```nix
inventory.instances.etcd = {
  module.name = "@UnstoppableMango/etcd";
  module.input = "cairn";

  roles.member.machines.cp1.settings = { ip = "10.10.0.11"; clusterName = "example"; };
  roles.member.machines.cp2.settings = { ip = "10.10.0.12"; clusterName = "example"; };
  roles.member.machines.cp3.settings = { ip = "10.10.0.13"; clusterName = "example"; };
};
```

### apiserver

Same shape as etcd: one entry per control-plane machine, each with its own IP.
`apiserverPort` and `serviceClusterIP` are left at their defaults (`6444` and `10.0.0.1`).

```nix
inventory.instances.apiserver = {
  module.name = "@UnstoppableMango/apiserver";
  module.input = "cairn";

  roles.control-plane.machines.cp1.settings = { ip = "10.10.0.11"; vip = "10.10.0.10"; clusterName = "example"; };
  roles.control-plane.machines.cp2.settings = { ip = "10.10.0.12"; vip = "10.10.0.10"; clusterName = "example"; };
  roles.control-plane.machines.cp3.settings = { ip = "10.10.0.13"; vip = "10.10.0.10"; clusterName = "example"; };
};
```

### kubelet

Control-plane machines only need their own IP (kubelet rides alongside the apiserver's own `master` role).
Worker machines need IP, VIP, and cluster name, since they have no apiserver service to pick those up from.

```nix
inventory.instances.kubelet = {
  module.name = "@UnstoppableMango/kubelet";
  module.input = "cairn";

  roles.control-plane.machines.cp1.settings.ip = "10.10.0.11";
  roles.control-plane.machines.cp2.settings.ip = "10.10.0.12";
  roles.control-plane.machines.cp3.settings.ip = "10.10.0.13";

  roles.worker.machines.worker1.settings = { ip = "10.10.0.21"; vip = "10.10.0.10"; clusterName = "example"; };
  roles.worker.machines.worker2.settings = { ip = "10.10.0.22"; vip = "10.10.0.10"; clusterName = "example"; };
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

  roles.control-plane.machines.cp1.settings = { vip = "10.10.0.10"; interface = "eth0"; virtualRouterId = 51; keepalivedPriority = 150; };
  roles.control-plane.machines.cp2.settings = { vip = "10.10.0.10"; interface = "eth0"; virtualRouterId = 51; keepalivedPriority = 100; };
  roles.control-plane.machines.cp3.settings = { vip = "10.10.0.10"; interface = "eth0"; virtualRouterId = 51; keepalivedPriority = 50; };
};
```

### network and kubeconfig

Both need only `vip` and `clusterName`, the same values on every machine, so the `all` tag works here too.

```nix
inventory.instances.network = {
  module.name = "@UnstoppableMango/network";
  module.input = "cairn";

  roles.node.tags.all = { settings = { vip = "10.10.0.10"; clusterName = "example"; }; };
};

inventory.instances.kubeconfig = {
  module.name = "@UnstoppableMango/kubeconfig";
  module.input = "cairn";

  roles.node.tags.all = { settings = { vip = "10.10.0.10"; clusterName = "example"; }; };
};
```

### inoculant and coredns (optional)

`inoculant` and `coredns` are only needed if you want cairn to bootstrap CoreDNS manifests for you.
Both run on the control-plane machines and reuse the `admin-cert` and kubeconfig from the `kubeconfig` service above.

```nix
inventory.instances.inoculant = {
  module.name = "@UnstoppableMango/inoculant";
  module.input = "cairn";

  roles.node.tags.control-plane = { };
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

## Generate Secrets

Before deploying, check the flake evaluates and generate the cluster's vars (secrets and certs):

```sh
nix flake check
clan vars generate
```

The `pki` service's CA generator prompts for a CA certificate and private key (PEM, pasted multi-line) the first time it runs, then signs every other certificate in the cluster against it.
If you already have CA material you want to reuse, for example when migrating an existing cluster's PKI trust onto cairn, set `cluster.cairn.pki.ca.override = { crt = "/path/to/ca.crt"; key = "/path/to/ca.key"; }` in a NixOS module on the relevant machines instead, and it copies that material in without prompting.
The same `override` option exists per-certificate under `cluster.cairn.pki.certs.<name>.override`.

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

SSH into any machine that has the `kubeconfig` instance (all five, in this example) and run `kubectl`.
The service already sets `KUBECONFIG` and installs `kubectl`:

```sh
ssh root@10.10.0.11
kubectl get nodes
kubectl get pods -A
```

You should see all five nodes `Ready`, with `cp1`/`cp2`/`cp3` holding the etcd quorum and the VIP.

## Where to Go From Here

- Each service's own `README.md` under `modules/service/<name>/README.md` documents its options and dependencies in more depth.
- `modules/service/AGENTS.md` covers the clan service authoring model, useful if you want to add a new service to cairn itself.
