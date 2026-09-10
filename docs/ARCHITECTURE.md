# Architecture

## Repo layout

- `clan.nix` — the flake's clan module registry (`modules."@UnstoppableMango/<name>"`) and (in `perSystem`) the single-node VM test's inventory wiring.
  This is the top-level list of what services exist.
- `flakeModules/` — the `flake.flakeModules.default` output: a flake-parts module consumer flakes import (`imports = [ inputs.cairn.flakeModules.default ];`).
  `default.nix` wires in clan-core's flake module and a default `systems` list, so a consumer gets clan without declaring `clan-core` as their own input, and declares the `cairn.clusters.<name>` option tree, which describes a whole cluster in one attrset.
  `cluster/options.nix` declares the surface and `cluster/lower.nix` turns one evaluated cluster into a clan module of `inventory.machines`, `inventory.instances`, and per-machine NixOS config.
  The option tree is inert when unused, so consumers hand-writing an inventory import the same module and leave `cairn.clusters` empty.
- `modules/service/<name>/` — one clan service per Kubernetes cluster component (`default.nix`, role files, `README.md`).
- `lib/` — small Nix helper library exposed as `flake.lib`: `kubeconfig.mkKubeconfig` for generating kubeconfig YAML, `options` for option definitions reused across service interfaces (`vip`/`clusterName`, `mkNodes`), `inventory` for inventory-shaped helpers (`mkMachines` merges shared per-role settings across per-machine entries; `nodesOf` turns a role's `machines` into the `mkNodes` shape), and `exports.endpointHosts` for reading another service's `endpoints` export.
- `modules/service/cluster.nix` — the facts a service needs to reach the apiserver (`cluster.cairn.{vip,apiServerPort,apiServerURL}`), declared once and imported by the role modules that need them.
  `modules/service/identity.nix` holds `cluster.cairn.clusterName` on its own, imported by `cluster.nix` and directly by roles that name the cluster without reaching its API, currently etcd.
  `modules/service/etcd-client.nix` declares the etcd client cert shared by the etcd and apiserver roles.
- `examples/single-node/` — a full, runnable consumer flake (its own `flake.nix` + `inventory.nix`) demonstrating a minimal one-machine cluster with a hand-written inventory (`cairn.clusters` left unset), plus a NixOS VM test (`tests/vm/default.nix`) that boots it and smoke-tests `kubectl`.
- `examples/ha-cluster/` — the same job done through the option tree: a 5-node HA cluster as one `cairn.clusters.example` value (`cluster.nix`), matching the topology in `docs/USAGE.md`.
  The spec lives apart from its `flake.nix` so `checks/flake-module.nix` can evaluate the exact thing the example ships.
- `docs/USAGE.md` — end-to-end walkthrough for building a multi-machine (5-node HA) consumer flake against cairn, covering both the `cairn.clusters` interface and the hand-written inventory underneath it.
- `modules/service/AGENTS.md` — the authoritative reference for the clan-service authoring model used throughout `modules/service/`.
  Read this before adding or modifying a service.

## Clan services model

Each entry under `modules/service/` is a clan service: a Nix module with `_class = "clan.service"` that deploys coordinated NixOS config across multiple machines via clan's inventory system (roles, `perInstance`/`perMachine`, settings, exports).
This is a different mechanism from plain NixOS modules.
Full details, required fields, and patterns (file splitting, `importApply` for injecting `self`/flake inputs, vars/secrets via `clan.core.vars.generators`, cross-machine exports) are documented in `modules/service/AGENTS.md`, treat that file as the primary spec when working in `modules/service/`.

Services are intentionally split per-component rather than one monolithic service, and each depends on others being co-assigned to the same machine(s):

| Service | Roles | Depends on |
| --- | --- | --- |
| `pki` | `node` | — (provides the CA; others consume it) |
| `etcd` | `member` | `pki` |
| `apiserver` | `control-plane` | `pki`, `etcd` (exports), `kubelet` (control-plane role) |
| `kubelet` | `control-plane`, `worker` | `pki` |
| `loadbalancer` | `control-plane` | `apiserver` (exports) |
| `network` | `node` | `pki`, running apiserver at the VIP |
| `kubeconfig` | `node` | `pki` |
| `inoculant` | `node` | `kubeconfig` (reuses its admin-cert) |
| `coredns` | `control-plane` | `inoculant`, `kubeconfig` |
| `flux` | `control-plane` | `inoculant`, `kubeconfig` |

Data flows between services via clan's **exports** mechanism (e.g. `etcd` exports member client URLs, consumed by `apiserver`'s `etcd.servers`; `apiserver` exports `ip:port`, consumed by `loadbalancer`'s HAProxy backend list) rather than direct option references across service boundaries.
Each service's own `README.md` documents its exports/consumes relationships precisely, check those before wiring a new dependency.

## `module.input` convention

Inside this repo's own examples/tests, `module.input = "self"` (cairn referencing its own modules).
In any external consumer flake, it must be the name given to the cairn flake input (e.g. `module.input = "cairn"`).
This distinction is called out explicitly in `docs/USAGE.md` and `modules/service/AGENTS.md`, don't copy `"self"` into consumer-flake examples.

## PKI trust

`pki` is the root of trust: it owns the CA (prompted via `clan vars generate` by default) and generic cfssl-based cert-generation machinery.
Other services declare their own certificate needs under `cluster.cairn.pki.certs.<name>` rather than minting certs themselves.
For migrating existing cluster PKI material in without prompting, both the CA (`cluster.cairn.pki.ca.override`) and individual certs (`cluster.cairn.pki.certs.<name>.override`) support an `override = { crt; key; }` escape hatch.
