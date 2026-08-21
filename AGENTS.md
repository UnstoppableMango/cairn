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
make check     # nix flake check — evaluates the flake and runs the NixOS VM test
make format    # nix fmt — formats via treefmt (nixfmt, mdformat, yamlfmt, jsonfmt, mbake)
make update    # nix flake update
```

Equivalent raw commands: `nix flake check`, `nix fmt`.

To run just the single-node VM test target directly:

```sh
nix build .#checks.x86_64-linux.single-node-cluster
```

CI (`.github/workflows/ci.yml`) runs only `nix flake check` on push to `main` and on PRs.

## Architecture

### Repo layout

- `clan.nix` — the flake's clan module registry (`modules."@UnstoppableMango/<name>"`) and (in `perSystem`) the single-node VM test's inventory wiring. This is the top-level list of what services exist.
- `modules/service/<name>/` — one clan service per Kubernetes cluster component (`default.nix`, role files, `README.md`).
- `lib/` — small Nix helper library exposed as `flake.lib` (`mkKubeconfig` for generating kubeconfig YAML, shared `options.nix` option definitions like `vip`/`clusterName` reused across service interfaces).
- `examples/single-node/` — a full, runnable consumer flake (its own `flake.nix` + `inventory.nix`) demonstrating a minimal one-machine cluster, plus a NixOS VM test (`tests/vm/default.nix`) that boots it and smoke-tests `kubectl`.
- `docs/USAGE.md` — end-to-end walkthrough for building a multi-machine (5-node HA) consumer flake against cairn.
- `modules/service/AGENTS.md` — the authoritative reference for the clan-service authoring model used throughout `modules/service/`. Read this before adding or modifying a service.

### Clan services model

Each entry under `modules/service/` is a clan service: a Nix module with `_class = "clan.service"` that deploys coordinated NixOS config across multiple machines via clan's inventory system (roles, `perInstance`/`perMachine`, settings, exports). This is a different mechanism from plain NixOS modules. Full details, required fields, patterns (file splitting, `importApply` for injecting `self`/flake inputs, vars/secrets via `clan.core.vars.generators`, cross-machine exports) are documented in `modules/service/AGENTS.md` — treat that file as the primary spec when working in `modules/service/`.

Services are intentionally split per-component rather than one monolithic service, and each depends on others being co-assigned to the same machine(s):

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
