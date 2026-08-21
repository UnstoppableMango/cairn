# cairn

A Kubernetes distribution built on Nix and clan.

[![CI](https://github.com/UnstoppableMango/cairn/actions/workflows/ci.yml/badge.svg)](https://github.com/UnstoppableMango/cairn/actions/workflows/ci.yml)
[![Last commit](https://img.shields.io/github/last-commit/UnstoppableMango/cairn)](https://github.com/UnstoppableMango/cairn/commits/main)
[![License](https://img.shields.io/github/license/UnstoppableMango/cairn)](LICENSE)
[![Built with Nix](https://img.shields.io/badge/built%20with-Nix-5277C3?logo=nixos&logoColor=white)](https://nixos.org)

## What is this?

Cairn provides a production-grade Kubernetes implementation on top of NixOS.
It leans heavily on NixOS's own `services.kubernetes` modules for components and configuration rather than reimplementing them.
A [clan](https://clan.lol) service configures the cluster across machines and is the primary entrypoint.

## What is clan?

[Clan](https://clan.lol) is a Nix-based framework for declaratively managing fleets of NixOS machines.
You describe an *inventory* of machines and the roles they play, and clan services wire up the coordinated configuration across all of them, things like generating and distributing secrets (`clan vars`), and deploying with a single `clan machines install` / `clan machines update` CLI.
It's not a widely adopted technology yet, but the model maps well onto running a Kubernetes cluster: each cluster component (etcd, the API server, kubelet, and so on) becomes a clan service with its own roles, and clan handles wiring the coordination between them.

Cairn doesn't reimplement any of this, it just registers a set of clan service modules that know how to run Kubernetes.

## Library, not a deployment

Cairn is a *library* flake.
It registers clan service modules (`@UnstoppableMango/pki`, `@UnstoppableMango/etcd`, and so on, see `clan.nix`) but declares no machines and no inventory of its own.

Deploying a real cluster means writing a *consumer* flake that adds cairn as an input and declares its own inventory against cairn's modules.

- **[docs/USAGE.md](docs/USAGE.md)** walks through building a full 5-machine HA cluster from scratch.
- **[examples/single-node](examples/single-node)** is a minimal, runnable consumer flake for a single-machine cluster, including a NixOS VM test that boots it and smoke-tests `kubectl`.

## Available services

Each Kubernetes component is its own clan service under `modules/service/`, so clusters can mix and match only what they need:

| Service | Roles | Depends on |
| --- | --- | --- |
| `pki` | `node` | — (provides the CA) |
| `etcd` | `member` | `pki` |
| `apiserver` | `control-plane` | `pki`, `etcd`, `kubelet` |
| `kubelet` | `control-plane`, `worker` | `pki` |
| `loadbalancer` | `control-plane` | `apiserver` |
| `network` | `node` | `pki`, running apiserver at the VIP |
| `kubeconfig` | `node` | `pki` |
| `inoculant` | `node` | `kubeconfig` |
| `coredns` | `control-plane` | `inoculant`, `kubeconfig` |
| `flux` | `control-plane` | `inoculant`, `kubeconfig` |

Each service's own `README.md` (`modules/service/<name>/README.md`) documents its options and exports in more depth.

## Development

```sh
make check   # nix flake check — evaluates the flake and runs the NixOS VM test
make format  # nix fmt — formats via treefmt (nixfmt, mdformat, yamlfmt, jsonfmt, mbake)
make update  # nix flake update
```

See [AGENTS.md](AGENTS.md) for the full architecture and contributor guidance.

## License

[MIT](LICENSE)
