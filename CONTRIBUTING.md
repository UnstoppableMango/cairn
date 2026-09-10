# Contributing

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

## Formatting

`nix fmt` (treefmt) covers Nix (`nixfmt`), Markdown (`mdformat`, excluding `.agents/skills/**` and `.claude/skills/**`), YAML, JSON, and the Makefile (`mbake`).
Run `make format` before committing rather than hand-formatting these files.

## Adding or changing a service

Each Kubernetes cluster component lives under `modules/service/<name>/` as a clan service.
See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for how the services model fits together, and `modules/service/AGENTS.md` for the authoritative reference on the clan-service authoring model (required fields, file layout, vars/secrets, cross-machine exports) before adding or modifying one.

## Before opening a PR

1. Run `make check` and confirm `nix flake check` passes, including the single-node VM test.
1. Run `make format` and commit any resulting changes.
1. If you touched a service's options or exports, update that service's own `README.md` to match.
