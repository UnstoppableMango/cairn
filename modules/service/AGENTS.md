# Clan Service Authoring Guide

Reference: https://clan.lol/docs/26.05/guides/services/community/

## What is a Clan Service

A clan service is a Nix module with `_class = "clan.service"` that deploys coordinated NixOS configuration across multiple machines. Unlike plain NixOS modules (under `modules/`), clan services integrate with the clan inventory system for role-based, multi-machine deployment.

Services in this repo live under `modules/service/<name>/` and are registered in `clan.nix`.

## Minimal Service

```nix
# modules/service/myservice/default.nix
{
  _class = "clan.service";
  manifest.name = "myservice";

  roles.server = {
    description = "What this role does";
    perInstance.nixosModule = ./server.nix;  # or inline module
  };
}
```

## Required Fields

| Field | Type | Notes |
|-------|------|-------|
| `_class` | `"clan.service"` | Identifies file as a service module |
| `manifest.name` | string | Unique name, used in error messages |
| `roles` | attrset | Must be non-empty |

Optional manifest fields: `manifest.description`, `manifest.readme` (use `builtins.readFile ./README.md`), `manifest.categories`, `manifest.exports.out`/`manifest.exports.inputs` (declares which export modules this service produces/consumes, see [Exports](#exports-cross-machine-data-sharing)), `manifest.constraints.maxInstances`, `manifest.constraints.roles.<role>.{minMachines,maxMachines}` (validated by `clan vars check` / CLI checks).

## Roles

Roles categorize machines by their function within a service. Two common patterns:

- **peer** — equivalent machines; can communicate directly (e.g., VPN nodes)
- **client-server** — hierarchical; clients unlikely to communicate with each other

Each role has:

- `description` — explains what the role does
- `interface.options` — configurable settings exposed to inventory
- `perInstance` — NixOS config applied per-instance-per-machine

```nix
roles.server = {
  description = "Runs the backend";
  interface.options.port = lib.mkOption { type = lib.types.port; default = 8080; };
  perInstance.nixosModule = ./server.nix;
};

roles.client = {
  description = "Connects to server";
  perInstance = { instanceName, settings, roles, ... }: {
    nixosModule = { config, ... }: {
      # settings.port comes from interface.options above
    };
  };
};
```

## perInstance vs perMachine

| | `perInstance` | `perMachine` |
|---|---|---|
| Runs | Once per (machine, instance) pair | Once per machine across all instances |
| Context | `instanceName`, `settings`, `machine`, `roles`, `extendSettings`, `mkExports` | `instances`, `machine`, `mkExports` |
| Use for | Instance-specific config | Global/shared config across instances |

Both return an attrset that may set `nixosModule`, `darwinModule` (for nix-darwin machines), and `exports`.

```nix
# perInstance as a function (gives access to context)
perInstance = { instanceName, settings, roles, machine, ... }: {
  nixosModule = { config, ... }: { /* ... */ };
  darwinModule = { config, ... }: { /* ... */ };  # optional, for aarch64-darwin machines
};

# perInstance as an attrset (simpler, no context needed)
perInstance.nixosModule = ./role.nix;
```

Prefer `roles.<roleName>.machines.<machineName>.settings` (via the `roles` argument) over `roles.<roleName>.settings` when you need a specific machine's settings — the latter is deprecated and will be removed.

## Registration in clan.nix

```nix
# clan.nix
{
  modules."@UnstoppableMango/myservice" = import ./modules/service/myservice;

  inventory.instances.myservice = {
    module.name = "@UnstoppableMango/myservice";
    module.input = "self";  # omit to use clan-core built-ins

    roles.server.tags.server = { };    # assign all machines tagged "server"
    roles.client.machines."node1" = { };  # assign specific machine
  };
}
```

`module.input` defaults to `null` (looked up among clan-core's built-in modules) if omitted. For local modules, always set `module.input = "self"`.

## Tags

Tags on `inventory.machines.<name>.tags` let you bulk-assign machines to roles:

```nix
# In clan.nix inventory.machines:
myhost = {
  tags = [ "server" "k8s" "pi4b" ];
};
# Host address goes in inventory.instances.internet.roles.default.machines.myhost.settings.host

# In inventory.instances:
roles.server.tags.server = { };  # all machines with tag "server" get this role
```

The special tag `all` matches every machine in the inventory.

## Settings

Settings flow from inventory → role interface options → nixosModule:

```nix
# Interface defines the option:
roles.client.interface.options.serverAddr = lib.mkOption {
  type = lib.types.str;
  description = "Server address";
};

# Inventory sets the value:
inventory.instances.myservice.roles.client.machines."node1" = {
  settings.serverAddr = "10.0.0.10";
};

# perInstance receives it:
perInstance = { settings, ... }: {
  nixosModule = { ... }: {
    services.myclient.server = settings.serverAddr;
  };
};
```

Declare each setting **once**. A setting that appears both in a role's `interface` and as an option of the role's NixOS module goes in `modules/service/<name>/options.nix` (`{ lib }: { <name> = lib.mkOption { ... }; }`), consumed from both sides:

```nix
# default.nix
interface = { lib, ... }: { options = import ./options.nix { inherit lib; }; };

# <role>.nix
options.cluster.cairn.<name> = import ./options.nix { inherit lib; };
```

Settings that several services share (`vip`, `clusterName`) come from `cairnLib.options` on the interface side and from `modules/service/cluster.nix` on the NixOS side: role modules `imports = [ ../cluster.nix ]` and their `perInstance` forwards `cluster.cairn.vip = settings.vip`, rather than each service declaring its own `cluster.cairn.<name>.vip`.
`types.str` merges definitions that agree, so several services forwarding the same value is fine and a disagreement is an eval error.

Use `extendSettings` for machine-local defaults that should NOT propagate to other machines:

```nix
perInstance = { extendSettings, ... }: {
  nixosModule = { config, ... }:
    let local = extendSettings { serverAddr = lib.mkDefault config.networking.hostName; };
    in { services.myclient.server = local.serverAddr; };
};
```

## Vars (Secrets & Generated Config)

Vars live in `clan.core.vars.generators.<name>` inside a NixOS module. They generate secrets/files on demand.

```nix
# In a nixosModule:
{ config, pkgs, ... }: {
  clan.core.vars.generators.myservice-secret = {
    prompts.password.description = "Service password";
    prompts.password.type = "hidden";  # or "line" for visible input

    files.password.secret = true;   # true = encrypted via sops, path only
    files.hash.secret = false;      # false = stored in nix store, .value accessible

    runtimeInputs = [ pkgs.mkpasswd ];
    script = ''
      mkpasswd -m sha-512 < "$prompts/password" > "$out/hash"
      cp "$prompts/password" "$out/password"
    '';
  };

  # Reference the generated file:
  services.myservice.passwordFile =
    config.clan.core.vars.generators.myservice-secret.files.password.path;
}
```

Run `clan vars generate` to execute generators. Secret files deploy to `/run/secrets/`, public files go to the nix store.

## Exports (Cross-Machine Data Sharing)

Exports share structured data between machines/instances. Experimental but available.
Declare what a service produces/consumes via `manifest.exports.out`/`manifest.exports.inputs` (list of export-module names, e.g. `[ "networking" "peer" ]`).

```nix
{ clanLib, ... }: {
  manifest.exports.out = [ "myserver" ];

  roles.server.perInstance = { mkExports, ... }: {
    exports = mkExports {
      server.address.plain = "10.0.0.10";
    };
    nixosModule = { ... }: { };
  };

  roles.client.perInstance = { exports, clanLib, ... }: {
    nixosModule = { ... }: {
      services.myclient.server =
        (clanLib.getExport { serviceName = "myservice"; roleName = "server"; } exports)
        .address.plain;
    };
  };
}
```

- `clanLib.getExport { serviceName?, instanceName?, roleName?, machineName? } exports` — fetch a single export by scope; throws if it isn't found.
- `clanLib.selectExports (scope: scope.serviceName == "myservice") exports` — filter exports with a **predicate function** over `{ serviceName, instanceName, roleName, machineName }` (all present as `""` when not part of the scope). `selectExports (_: true) exports` returns everything.

## File Splitting Pattern

For complex services, split role logic into separate files:

```
modules/service/myservice/
├── default.nix       # _class, manifest, roles (references other files)
├── common.nix        # shared NixOS config imported by role files
├── server.nix        # server role nixosModule
├── client.nix        # client role nixosModule
└── README.md         # used by manifest.readme
```

```nix
# default.nix
{
  _class = "clan.service";
  manifest.name = "myservice";
  manifest.readme = builtins.readFile ./README.md;

  roles.server.perInstance.nixosModule = ./server.nix;
  roles.client.perInstance.nixosModule = ./client.nix;
}

# server.nix - imports common config
{ config, ... }: {
  imports = [ ./common.nix ];
  services.myservice.role = "server";
}
```

## Dependency Injection (importApply)

When a service needs something the module system won't hand it (a flake input, `cairnLib`), use `importApply`:

```nix
# flake.nix — the one place that touches `inputs`
clan.imports = [
  (lib.modules.importApply ./clan.nix {
    inherit cairnLib;
    inherit (inputs) someInput;
  })
];

# clan.nix — receives them by closure, forwards them the same way
{ cairnLib, someInput }:
{ lib, ... }:
{
  modules."@UnstoppableMango/myservice" = lib.modules.importApply ./modules/service/myservice {
    inherit cairnLib someInput;
  };
}

# modules/service/myservice/default.nix
{ cairnLib, someInput }: {
  _class = "clan.service";
  manifest.name = "myservice";
  # cairnLib and someInput available here
}
```

Flake inputs enter the module tree exactly once, in `flake.nix`, and travel down by lexical closure.
Do not reach for an `inputs` module argument anywhere under `modules/service/` or in `clan.nix`.
`clan.specialArgs` does *not* supply module arguments to `clan.nix`; it sets the `specialArgs` passed to each machine's `nixosSystem`.
So an `inputs` module argument falls back to `_module.args.inputs`, which nothing defines.
Because `importApply` is lazy, that only explodes once a machine is actually assigned the role, with `error: attribute 'inputs' missing` ([#37](https://github.com/UnstoppableMango/cairn/issues/37)).

`self` is the same trap one level removed.
`self.inputs` and `self.lib` do resolve in `clan.nix` today, but they re-open the flake from inside a module that has no other reason to know cairn is a flake, and they silently depend on whichever `self` the current evaluation pass supplies.
`clan.nix` therefore takes no `self` argument at all.
Pass the specific value down the closure instead.

Any service that closes over a flake input this way needs coverage that actually assigns its role, otherwise the breakage stays invisible to CI.
See `checks/consumer-services.nix`.

## Existing Services in This Repo

The cairn cluster is composed from these per-component services rather than
one monolithic service. See each service's own `README.md` for what it owns
and which other services it depends on being co-assigned to the same
machine.

| Module | Roles | Notes |
|--------|-------|-------|
| `@UnstoppableMango/pki` | `node` | CA + cfssl cert-generator machinery; consumers declare their own cert specs |
| `@UnstoppableMango/etcd` | `member` | etcd cluster member; exports client URLs |
| `@UnstoppableMango/apiserver` | `control-plane` | kube-apiserver, controller-manager, scheduler; consumes etcd exports, exports node info |
| `@UnstoppableMango/kubelet` | `node` | kubelet, on any machine that should appear as a Kubernetes node |
| `@UnstoppableMango/loadbalancer` | `control-plane` | keepalived VIP + HAProxy fronting the apiserver cluster |
| `@UnstoppableMango/network` | `node` | Flannel CNI + kernel bridge/forwarding prerequisites |
| `@UnstoppableMango/kubeconfig` | `node` | Installs the admin kubeconfig + kubectl |
| `@UnstoppableMango/inoculant` | `node` | Shared inoculant `clusterAdmin` wiring for coredns/flux, plus `nodeLabels` |
| `@UnstoppableMango/coredns` | `control-plane` | Optional CoreDNS bootstrap via inoculant |
| `@UnstoppableMango/flux` | `control-plane` | Optional Flux GitOps bootstrap via inoculant |

## Checklist: New Service

1. Create `modules/service/<name>/default.nix` with `_class = "clan.service"` and `manifest.name`
1. Define at least one role with `perInstance.nixosModule`
1. Register in `clan.nix`: `modules."@UnstoppableMango/<name>" = import ./modules/service/<name>;`
1. Add inventory instance in `clan.nix` with `module.input = "self"` and role assignments
1. Tag machines appropriately in `inventory.machines` or list them explicitly
1. Expose it through the flake module: a `services.<name>` block in `flakeModules/cluster/options.nix` and the matching instance in `flakeModules/cluster/lower.nix`. The same applies when adding an option to an existing service; consumers configure cairn through `cairn.clusters`, so a setting that isn't there is only reachable via the `settings` escape hatch
1. Run `make check` to verify
