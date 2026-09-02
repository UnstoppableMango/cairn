# AGENTS.md

This file provides guidance to AI coding agents (Claude Code, GitHub Copilot, and others) when working with code in this repository.

## Project Goals

Provide a production-grade Kubernetes implementation on top of NixOS.
NixOS modules (`services.kubernetes`, etc.) are leaned on heavily for components and configuration rather than reimplemented.
A [clan](https://clan.lol) service configuring the cluster on machines is the primary entrypoint.

Cairn itself is a library flake: it registers clan service modules but declares no machines and no inventory of its own.
Deploying a real cluster means writing a *consumer* flake that adds cairn as an input and declares its own `inventory` against cairn's modules (see `docs/USAGE.md` and `examples/single-node`).

## Commands

```sh
make check     # nix flake check --option allow-import-from-derivation true — evaluates the flake and runs the NixOS VM test
make format    # nix fmt — formats via treefmt (nixfmt, mdformat, yamlfmt, jsonfmt, mbake)
make update    # nix flake update
```

Equivalent raw commands: `nix flake check --option allow-import-from-derivation true`, `nix fmt`.

The single-node-cluster VM test provisions its vars/secrets via clan's generator machinery, which clan-core builds during evaluation (import-from-derivation). That flag is passed explicitly on `check` rather than pinned via the flake's `nixConfig`, since a flake `nixConfig` setting is reapplied on every command run directly against this repo (overriding even an opposing `--option` on the command line) — pinning it there would force IFD on for every such command, not just `check`.

To run just the single-node VM test target directly:

```sh
nix build .#checks.x86_64-linux.single-node-cluster --option allow-import-from-derivation true
```

CI (`.github/workflows/ci.yml`) runs only `nix flake check --option allow-import-from-derivation true` on push to `main` and on PRs.

## Architecture

### Repo layout

- `clan.nix` — the flake's clan module registry (`modules."@UnstoppableMango/<name>"`) and (in `perSystem`) the single-node VM test's inventory wiring. This is the top-level list of what services exist.
- `flakeModules/` — the `flake.flakeModules.default` output, the flake-parts module consumer flakes import (`imports = [ inputs.cairn.flakeModules.default ];`). `default.nix` wires in clan-core's flake module and a default `systems` list (so a consumer needs no `clan-core` input of their own) and declares the `cairn.clusters.<name>` option tree: a whole cluster in one attrset. `cluster/options.nix` declares the surface (machines with a `role`/`ip`, and a `services.<name>` block per cairn service, mirroring every role `interface` plus the cairn NixOS options no inventory setting reaches); `cluster/lower.nix` turns one evaluated cluster into a clan module of `inventory.machines`, `inventory.instances` and per-machine NixOS config. Adding an option to a service means adding it to both files. The option tree is inert when unused, so consumers hand-writing an inventory import the same module and leave `cairn.clusters` empty.
- `modules/service/<name>/` — one clan service per Kubernetes cluster component (`default.nix`, role files, `README.md`).
- `lib/` — small Nix helper library exposed as `flake.lib`: `kubeconfig.mkKubeconfig` for generating kubeconfig YAML, `options` for option definitions reused across service interfaces (`vip`/`clusterName`, `mkNodes`), `inventory` for inventory-shaped helpers (`mkMachines` merges shared per-role settings across per-machine entries; `nodesOf` turns a role's `machines` into the `mkNodes` shape), and `exports.endpointHosts` for reading another service's `endpoints` export.
- `modules/service/cluster.nix` — the facts a service needs to reach the apiserver (`cluster.cairn.{vip,apiServerPort,apiServerURL}`), declared once and imported by the role modules that need them. `modules/service/identity.nix` holds `cluster.cairn.clusterName` on its own, imported by `cluster.nix` and directly by roles that name the cluster without reaching its API, currently etcd. `modules/service/etcd-client.nix` declares the etcd client cert shared by the etcd and apiserver roles.
- `examples/single-node/` — a full, runnable consumer flake (its own `flake.nix` + `inventory.nix`) demonstrating a minimal one-machine cluster with a hand-written inventory (`cairn.clusters` left unset), plus a NixOS VM test (`tests/vm/default.nix`) that boots it and smoke-tests `kubectl`.
- `examples/ha-cluster/` — the same job done through the option tree: a 5-node HA cluster as one `cairn.clusters.example` value (`cluster.nix`), matching the topology in `docs/USAGE.md`. The spec lives apart from its `flake.nix` so `checks/flake-module.nix` can evaluate the exact thing the example ships.
- `checks/flake-module.nix`: an evaluation-only flake check covering the `cairn.clusters` interface. It runs `examples/ha-cluster/cluster.nix` through the option tree and the lowering, asserts specific facts about the generated inventory, then feeds the result to `clan-core.lib.clan` and forces a control-plane and a worker machine. Nothing else in CI touches those two files: the VM test writes its inventory by hand, and `nix flake check` never descends into the example flakes.
- `checks/consumer-services.nix`: an evaluation-only flake check that resolves cairn's modules the way a downstream consumer does (`module.input = "cairn"`, read off `self.inputs`) and forces the services the VM test can't cover, currently `inoculant` and `flux`. These are the only two services that close over cairn's own flake inputs, so nothing else catches them breaking.
- `checks/split-topology.nix`: an evaluation-only flake check covering a machine that runs etcd without the apiserver, and one that runs the apiserver without etcd. Both examples co-locate the two, so nothing else in CI evaluates a machine that has one and not the other, which is where cross-service certificate declarations and `cluster.cairn.*` option declarations stop lining up. See `docs/TOPOLOGY.md`.
- `docs/USAGE.md` — end-to-end walkthrough for building a multi-machine (5-node HA) consumer flake against cairn, covering both the `cairn.clusters` interface and the hand-written inventory underneath it.
- `modules/service/AGENTS.md` — the authoritative reference for the clan-service authoring model used throughout `modules/service/`. Read this before adding or modifying a service.

### Clan services model

Each entry under `modules/service/` is a clan service: a Nix module with `_class = "clan.service"` that deploys coordinated NixOS config across multiple machines via clan's inventory system (roles, `perInstance`/`perMachine`, settings, exports). This is a different mechanism from plain NixOS modules. Full details, required fields, patterns (file splitting, `importApply` for injecting `self`/flake inputs, vars/secrets via `clan.core.vars.generators`, cross-machine exports) are documented in `modules/service/AGENTS.md` — treat that file as the primary spec when working in `modules/service/`.

Services are intentionally split per-component rather than one monolithic service, and each depends on others being co-assigned to the same machine(s):

**Service dependencies:**

| Service | Roles | Depends on |
|---|---|---|
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

Data flows between services via clan's **exports** mechanism (e.g. `etcd` exports member client URLs, consumed by `apiserver`'s `etcd.servers`; `apiserver` exports `ip:port`, consumed by `loadbalancer`'s HAProxy backend list) rather than direct option references across service boundaries. Each service's own `README.md` documents its exports/consumes relationships precisely; check those before wiring a new dependency.

### `module.input` convention

Inside this repo's own examples/tests, `module.input = "self"` (cairn referencing its own modules). In any external consumer flake, it must be the name given to the cairn flake input (e.g. `module.input = "cairn"`). This distinction is called out explicitly in `docs/USAGE.md` and `modules/service/AGENTS.md` — don't copy `"self"` into consumer-flake examples.

### PKI trust

`pki` is the root of trust: it owns the CA (prompted via `clan vars generate` by default) and generic cfssl-based cert-generation machinery. Other services declare their own certificate needs under `cluster.cairn.pki.certs.<name>` rather than minting certs themselves. For migrating existing cluster PKI material in without prompting, both the CA (`cluster.cairn.pki.ca.override`) and individual certs (`cluster.cairn.pki.certs.<name>.override`) support an `override = { crt; key; }` escape hatch.

### Formatting

`nix fmt` (treefmt) covers Nix (`nixfmt`), Markdown (`mdformat`, excluding `.agents/skills/**` and `.claude/skills/**`), YAML, JSON, and the Makefile (`mbake`). Run it before committing rather than hand-formatting these files.
