# Clan Service Authoring Guide

Reference: https://clan.lol/docs/25.11/guides/services/community/

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

Optional manifest fields: `manifest.description`, `manifest.readme` (use `builtins.readFile ./README.md`), `manifest.categories`.

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
| Context | `instanceName`, `settings`, `machine`, `roles` | `instances`, `machine` |
| Use for | Instance-specific config | Global/shared config across instances |

```nix
# perInstance as a function (gives access to context)
perInstance = { instanceName, settings, roles, machine, ... }: {
  nixosModule = { config, ... }: { /* ... */ };
};

# perInstance as an attrset (simpler, no context needed)
perInstance.nixosModule = ./role.nix;
```

## Registration in clan.nix

```nix
# clan.nix
{
  modules."@UnstoppableMango/myservice" = import ./modules/service/myservice;

  inventory.instances.myservice = {
    module.name = "@UnstoppableMango/myservice";
    module.input = "self";  # omit to use clan-core built-ins

    roles.server.tags.server = { };    # assign all machines tagged "server"
    roles.client.machines."agreus" = { };  # assign specific machine
  };
}
```

`module.input` defaults to `"clan-core"` if omitted. For local modules, always set `module.input = "self"`.

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
inventory.instances.myservice.roles.client.machines."agreus" = {
  settings.serverAddr = "192.168.1.100";
};

# perInstance receives it:
perInstance = { settings, ... }: {
  nixosModule = { ... }: {
    services.myclient.server = settings.serverAddr;
  };
};
```

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

```nix
{ clanLib, ... }: {
  roles.server.perInstance = { mkExports, ... }: {
    exports = mkExports {
      server.address.plain = "192.168.1.100";
    };
    nixosModule = { ... }: { };
  };

  roles.client.perInstance = { exports, ... }: {
    nixosModule = { ... }: {
      services.myclient.server =
        (clanLib.selectExports { service = "myservice"; role = "server"; } exports)
        .address.plain;
    };
  };
}
```

`clanLib.selectExports` filters by `service`, `instance`, `role`, `machine` (all optional, default wildcard).

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

When a service needs access to flake inputs (e.g., `self`, `pkgs`), use `importApply`:

```nix
# clan.nix
modules."@UnstoppableMango/myservice" = lib.importApply ./modules/service/myservice { inherit self inputs; };

# modules/service/myservice/default.nix
{ self, inputs }: {
  _class = "clan.service";
  manifest.name = "myservice";
  # self and inputs available here
}
```

## Existing Services in This Repo

| Module | Roles | Notes |
|--------|-------|-------|
| `@UnstoppableMango/k3s` | `control-plane`, `worker` | Uses vars for k3s token; common config in `k3s.nix` |
| `@UnstoppableMango/pi` | `pi4b` | Hardware config for Raspberry Pi 4B |
| `@UnstoppableMango/trouble` | `server` | Minimal debug tooling service |

## Checklist: New Service

1. Create `modules/service/<name>/default.nix` with `_class = "clan.service"` and `manifest.name`
2. Define at least one role with `perInstance.nixosModule`
3. Register in `clan.nix`: `modules."@UnstoppableMango/<name>" = import ./modules/service/<name>;`
4. Add inventory instance in `clan.nix` with `module.input = "self"` and role assignments
5. Tag machines appropriately in `inventory.machines` or list them explicitly
6. Run `make check` to verify
