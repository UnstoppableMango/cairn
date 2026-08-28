# Cluster Upgrades

This document is the design for upgrading a running cairn cluster: new Kubernetes minors, new nixpkgs pins, and the machinery that makes a rolling upgrade safe.
It records the architectural decisions first, then the phased implementation plan, then the manual runbook the tooling automates.

Status: design.
None of the phases below are implemented yet.

## Summary of Decisions

- **Clan remains the only deploy transport.**
  `clan machines update` already does the hard parts correctly: it builds on the target, registers the new generation in the bootloader (`switch-to-configuration boot`) before switching live, and wraps activation in `systemd-run` so it survives an SSH drop.
  Nothing here replaces or duplicates that pipeline.
- **A thin push orchestrator sequences updates.**
  Clan updates all selected machines in parallel with no ordering, health gates, hooks, or rollback command, and its eval-time exports cannot express runtime coordination.
  Rather than fight that model, a small flake app (`nix run .#upgrade`) invokes `clan machines update <machine>` one machine at a time and gates each step on etcd, apiserver, and node health.
  It deploys nothing itself.
- **Kubernetes versions come from [kubepkgs](https://github.com/unmango/kubepkgs), not from whichever nixpkgs happens to be locked.**
  kubepkgs exposes per-minor package sets (`kubernetes."1.33"` through `"1.36"` plus `latest`), which makes "hold the cluster at 1.34 while nixpkgs moves" and "step 1.34 to 1.35 to 1.36 one minor at a time" first-class operations.
- **Inoculant stays dumb.**
  It already carries in-cluster manifest migrations (CoreDNS, flux) by re-firing when its manifest hash changes during a normal switch.
  It gains no leases, waits, or ordering; it is per-node, one-shot, and has no view of the rollout.
- **Node-local coordination via activation scripts or pre-switch inhibitors is rejected as the primary mechanism.**
  A worker-only drain hook survives as an optional hardening phase, detailed below.
- **An in-cluster pull operator is rejected.**
  Watching a flake ref from inside the cluster inverts the trust model, duplicates clan's transport, and cannot safely upgrade the control plane it runs on.

## Why Not the Alternatives

### Runbook only

A manual upgrade of the five-node reference topology is roughly thirty ordered steps: five machines, each with an update, three health polls, and (for workers) cordon, drain, and uncordon.
That toil profile is exactly what produces skipped health checks.
The runbook still exists (see below) as the fallback when the orchestrator is unavailable, but it is the documentation of what the tool does, not the primary interface.

### Node-local self-coordination (kured-style)

The tempting pure-nix design is a NixOS pre-switch check on every node that acquires a cluster-wide coordination `Lease` using the node's admin kubeconfig, cordons and drains itself, and only then permits `switch-to-configuration` to proceed, with a post-switch unit that uncordons after the node reports Ready.
That would make even a parallel `clan machines update` self-serializing.
It fails on four points:

1. etcd is the hard case, and a `Lease` cannot express it.
   The lease serializes machines, but quorum safety is a cluster-level judgment ("is any other member already unhealthy?") wedged into a node-local script that talks to the apiserver through the very VIP whose backend is about to restart.
1. Clan surfaces an inhibited switch as a "reboot required" style error.
   With three control-plane machines updated in parallel, two of them fail with that message and must be retried, so the operator ends up hand-sequencing anyway, with worse diagnostics.
   `--no-check` also silently defeats the entire guard.
1. Bootstrap deadlocks.
   The first install has no apiserver to acquire a lease from, so every inhibitor needs a "cluster not up yet" escape hatch, which is precisely the hole that makes the guarantee soft.
1. A drain can take minutes, and a multi-minute block inside `switch-to-configuration` is miserable to observe and interacts badly with clan's single activation retry.

## Version Model

### kubepkgs as the version source

cairn takes `kubepkgs` as a flake input, injected into the services via `importApply` the same way `a2b` and `inoculant` are (see `modules/service/AGENTS.md`), with coverage added in `checks/consumer-services.nix` since input-closing services are otherwise invisible to CI.

kubepkgs ships each supported Kubernetes minor as a package set of individually built components: `kubectl`, `kubeadm`, `kubelet`, `kube-apiserver`, `kube-controller-manager`, `kube-scheduler`, and `kube-proxy`, plus SIG projects, all pinned in `versions.json`/`hashes.json`.

The nixpkgs `services.kubernetes` module takes a single combined package (`services.kubernetes.package`) and expects every component under its `bin/`, plus a `pause` passthru derivation that `kubelet.nix` wraps into the sandbox image.
The lowering therefore builds a `symlinkJoin` of the kubepkgs components for the selected minor and attaches `passthru.pause`.
The pause shim is a tiny version-insensitive C binary, so reusing `pkgs.kubernetes.pause` from nixpkgs is correct until kubepkgs grows its own `pause` package.
`bin/kube-addons` is referenced only by the addon manager, which cairn disables, so the joined package does not need it.

### Options

Declared in `flakeModules/cluster/options.nix` and threaded through `flakeModules/cluster/lower.nix` into the apiserver, kubelet, and etcd service settings:

- `cairn.clusters.<name>.versions.kubernetes` (`nullOr str`, e.g. `"1.35"`): selects the kubepkgs minor.
  `null` (the default) follows `pkgs.kubernetes` from nixpkgs, preserving the zero-config behavior.
- `cairn.clusters.<name>.versions.kubernetesPackage` (`nullOr package`): escape hatch for a fully custom combined package; mutually exclusive with `versions.kubernetes`.
- `cairn.clusters.<name>.versions.etcdPackage` (`nullOr package`): sets `services.etcd.package`.
  kubepkgs does not ship etcd, so pinning etcd independently of nixpkgs means passing a package here.
  Folding etcd into kubepkgs is a natural follow-up.

Consumers hand-writing an inventory get the same knobs as service settings, per the usual two-file rule for the option tree.

### Skew rules

The Kubernetes version skew policy constrains everything below:

- kubelet may be up to three minors behind the apiserver, never ahead.
- The apiserver moves one minor at a time.
- etcd members restart one at a time, preserving quorum.

A version bump moves every component on a machine together, the same shape as upgrading a kubeadm node.
Rolling control-plane machines first and workers second therefore satisfies skew automatically, provided machines move one at a time and the bump is a single Kubernetes minor.

Two eval-time guards enforce this:

- An assertion that the configured kubelet minor is not ahead of the apiserver minor (exports are usable at eval time, so the check spans services).
- A multi-minor bump of `versions.kubernetes` fails evaluation with a pointer to the one-minor-at-a-time procedure.

A multi-minor upgrade is a sequence of single-minor upgrades: bump `versions.kubernetes` from N to N+1, run the orchestrator, commit, repeat.
Each commit is a valid rollback target.
Apiserver minor downgrades are unsupported upstream, which bounds the rollback story below.

Per-component packages also make same-machine skew possible in principle (apiserver ahead of kubelet on a single-node cluster, via unit `ExecStart` overrides).
That is noted as a possible extension and deliberately out of scope.

## Phased Implementation

### Phase 0: hardening

Pure nix changes worth landing regardless of the rest of the design.

- **HAProxy readiness checks** (`modules/service/loadbalancer/control-plane.nix`): replace `option tcp-check` with `option httpchk GET /readyz` and `http-check expect status 200` against the apiserver backends on their real port, so a backend drops out of rotation when the apiserver is unready, not merely unreachable.
- **keepalived tracks apiserver health** (same file): add a track script curling the local apiserver's `/readyz`, with a weight large enough (60, against priorities 150/100/50) that a node whose apiserver is down loses the VIP election.
  Without this the VIP only moves when keepalived itself dies, so restarting the apiserver on the VIP holder blackholes the cluster for the duration.
  Both behaviors get options in `modules/service/loadbalancer/options.nix` (`healthCheck.enable` defaulting to `true`, probe interval, weight) so the eval checks can assert on them.
- **Bulk updates become inert** (`flakeModules/cluster/lower.nix`): set `clan.core.deployment.requireExplicitUpdate = true` on every cairn machine, exposed as a cluster-level option defaulting to `true`.
  This is the single most important safety change: a bare `clan machines update` restarts every etcd member and apiserver simultaneously, and this one line makes that a no-op for cluster machines, forcing the per-machine invocation the orchestrator performs.
- **etcd rejoins instead of re-initializing** (`modules/service/etcd/member.nix`): steady-state machines run with `initialClusterState = "existing"`; only bootstrap uses `"new"`.

### Phase 1: version surface

The kubepkgs input, the `versions.*` options, the `symlinkJoin` lowering, and the skew assertions described above.

### Phase 2: the orchestrator

A `writeShellApplication` in `pkgs/upgrade/` with `kubectl`, `etcdctl`, `jq`, and the clan CLI in `runtimeInputs`, exposed as `packages.upgrade` and `apps.upgrade` in `flake.nix` `perSystem`.
Shell is sufficient at this size; a rewrite in Go is justified only if it grows real state.

The machine ordering comes from the same evaluation the cluster is built from, not a hand-maintained list: the lowering additionally emits an upgrade plan (`nix eval .#cairn-upgrade-plan --json`), an ordered list of `{ machine, roles, targetHost }` with control-plane machines first.

The run:

1. `etcdctl snapshot save` on one member, stored on the operator's machine.
1. For each control-plane machine, serially:
   - Pre-gate: every etcd member healthy (`etcdctl endpoint health --cluster`), every apiserver answering `/readyz` with 200 probed directly on its backend port rather than through the VIP, and a refusal to proceed if any other member is already unhealthy (the quorum-loss guard).
   - `clan machines update <machine>`.
   - Post-gate with timeout: the local etcd member rejoined and healthy, `/readyz` 200, the node Ready, the HAProxy backend back up.
     Because etcd and the apiserver are colocated, per-machine serialization satisfies the etcd one-member-at-a-time rule and the apiserver-before-kubelet ordering at once.
1. For each worker, serially: `kubectl cordon`, `kubectl drain --ignore-daemonsets --delete-emptydir-data` with a timeout, `clan machines update <machine>`, wait for Ready with the kubelet reporting the target version, `kubectl uncordon`.

Flags: `--only <machine>` to resume a rollout mid-way, `--skip-drain`, `--dry-run` to print the plan and gates without acting, and `--rollback <machine>`.
Any gate failure stops the rollout before the next machine and prints the observed state.

### Phase 3: runbook

The manual procedure in this document, kept in sync with the orchestrator.

### Phase 4 (optional): worker drain hooks

If unattended or accidental single-machine updates cause real incidents, a `modules/service/upgrade/` clan service can add, on workers only, a pre-switch check that self-cordons and drains using the node's admin kubeconfig, and a post-switch oneshot that waits for self-Ready and uncordons.
Workers only, because they carry no quorum logic, and with a "no apiserver reachable" pass-through for bootstrap.
This is defense in depth for the unorchestrated path, not a requirement of the design.

## Rollback

- **Single machine.**
  Clan runs `switch-to-configuration boot` before switching live, so the previous generation is always registered in the bootloader.
  `--rollback <machine>` runs, over SSH, `nix-env --profile /nix/var/nix/profiles/system --rollback && /nix/var/nix/profiles/system/bin/switch-to-configuration switch`; the worst case is a reboot into the previous boot entry.
  Safe at any time.
- **Fleet.**
  `git revert` the version bump and re-run the orchestrator.
  Only safe before the first control-plane machine's post-gate passed, because apiserver minor downgrades are unsupported once the new version has written to etcd.
  Past that point, recovery is the step-0 etcd snapshot: restore it, then roll the machines back generation by generation.

| Situation | Action |
| --- | --- |
| Gate failed on machine N, others untouched | Fix or `--rollback` machine N; rollout never advanced |
| Regret after first control-plane post-gate passed | Roll forward if possible; otherwise etcd snapshot restore plus per-machine generation rollback |
| Worker misbehaving after upgrade | `--rollback` that worker; skew allows old kubelet against new apiserver |

## Manual Runbook

The sequence the orchestrator automates, for when it is unavailable.
It assumes Phase 0 has landed.

1. Take an etcd snapshot: `etcdctl snapshot save` against any healthy member.
1. Bump the version (one minor at most) and commit.
1. For each control-plane machine in turn:
   1. Verify every etcd member is healthy and every apiserver answers `/readyz`.
      Do not proceed if any other machine is unhealthy.
   1. `clan machines update <machine>`.
   1. Wait until the local etcd member is healthy, `/readyz` returns 200, and `kubectl get nodes` shows the node Ready at the target version.
1. For each worker in turn: cordon, drain, `clan machines update <machine>`, wait for Ready at the target version, uncordon.
1. Verify cluster health end to end (`kubectl get nodes`, workloads rescheduled, CoreDNS serving).

## Mechanism Choices

| Concern | Mechanism | Why |
| --- | --- | --- |
| Deploy transport, atomicity, boot entries | clan, unchanged | Already correct; duplicating it buys nothing |
| Preventing parallel quorum loss | pure nix (`requireExplicitUpdate`) | One line, total coverage |
| VIP and backend health | pure nix (HAProxy, keepalived config) | Static config, no runtime logic needed |
| Version selection and skew guards | pure nix (kubepkgs + options + assertions) | Eval-time facts; exports work here |
| Cross-machine ordering, health gates, drain | new tool (flake app) | Runtime cluster state; clan has no primitive for it and should not grow one |
| In-cluster manifests during upgrade | inoculant, unchanged | Content-addressed re-fire already does this; it must not become a coordinator |
| Rollback | nix generations + git | Already present; the tool only fronts it |

kubepkgs' SIG packages (`metrics-server`, `kube-state-metrics`, `external-dns`) are natural future cairn addons delivered through inoculant, versioned in lockstep with the cluster minor.

## Testing

- **Eval checks** (`checks/flake-module.nix`, `checks/consumer-services.nix`): the new loadbalancer health-check settings, `requireExplicitUpdate` present in the lowered inventory, `versions.*` threading into service settings, the skew assertion firing on a deliberately bad pin, and the shape and ordering of the upgrade-plan JSON (control plane before workers).
- **VM tests**: a single-node subtest that kills the apiserver and asserts the HAProxy backend goes down and `/readyz` gating fails; an HA VM test that pre-stages two generations one patch apart, flips one control-plane node between them, and asserts the other apiservers stay ready and etcd keeps quorum.
  That is the exact restart the orchestrator gates on, exercised without clan-over-SSH inside the test.
  The orchestrator itself gets a `--dry-run` test against the evaluated plan JSON.
- **`examples/ha-cluster`** remains the manual end-to-end proving ground for a real upgrade run.
