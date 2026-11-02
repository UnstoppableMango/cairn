# Prior art for running NixOS fleet deploys from a service

Research for [#142](https://github.com/UnstoppableMango/cairn/issues/142).
Question: how do tools that deploy NixOS machines from a long-running service handle credentials and the flake, and which of their patterns could clan support?
It feeds the design of clan-operator, which runs clan operations from a Kubernetes controller or a NixOS service on a clan machine.

## Sources and pinning

- **clan-core**: `git.clan.lol` is not reachable from this environment (proxy 403), so citations use the GitHub mirror `github.com/clan-lol/clan-core`.
  Pinned at `633df331bc48162cf1e23614d7b1f7b24f37e43f` (2026-06-23, just after `26.05` was enabled; the same commit `clan-core-programmatic-api.md` uses).
  Every clan claim below was also checked at `61bf39e60` (`main`, 2026-10-14, the date of cairn's locked `606b846`) and holds there unchanged.
- **clan-community** (`dm-pull-deploy`): the source could not be fetched (robots / proxy). Only the 26.05 release notes and the clan.lol data-mesher blog post describe it.
- **comin** `f954511` (2026-10-27), **deploy-rs** `1cec052` (2026-10-20), **colmena** `fc7d67e` (2026-10-30), **hercules-ci-effects** `9eecf40` (2026-10-18), **cachix** `8693fba` (2026-10-22), **nixpkgs** `nixos/modules/tasks/auto-upgrade.nix` on `nixos-unstable` (fetched 2026-11-02).

## Comparison

| Tool | Push / pull | Where it evaluates and builds | Credentials the runner holds | How secrets reach the machine | Result and deployed toplevel |
|---|---|---|---|---|---|
| comin | Pull: a daemon on each machine polls Git | On the machine (eval + build, substituting from its caches) | None central. Each machine holds read access to the Git remote (token or SSH deploy key file) | Not comin's concern: sops-nix / agenix decrypt with machine-local keys at activation | Prometheus exporter (`comin_deployment_info{commit_id,status}`, `comin_last_*_failed`, `comin_need_to_reboot`), `comin status`, post-build / post-deploy hooks with `COMIN_GIT_SHA`, `COMIN_GENERATION`, `COMIN_STATUS` |
| `system.autoUpgrade` | Pull: a systemd timer on each machine | On the machine (`nixos-rebuild switch --refresh --flake <ref>`) | None central. Machine needs read access to the flake ref | Same as comin: machine-local keys | Only the `nixos-upgrade.service` unit result and journal |
| Cachix Deploy | Pull-on-notify: agent holds a websocket to the Cachix backend; CI pushes a spec | In CI. The agent does no eval or build, it `nix-store -r`s the store path from the binary cache | CI holds `CACHIX_ACTIVATE_TOKEN` (and the cache push token). Each agent holds `CACHIX_AGENT_TOKEN` | Not handled: machine-local keys | Backend records per-agent deployment status; `cachix deploy activate` streams logs and exits non-zero unless every deployment `Succeeded`; optional rollback script |
| Hercules CI effects (`runNixOS`) | Push: CI agent SSHes in | Hercules agent evaluates and builds; optional `buildOnDestination` | Agent `secrets.json` holds an SSH private key (`secretsMap.ssh`), conventionally authorised for **root** on the target | Not handled: machine-local keys (or extra effect steps) | Effect status in Hercules CI; the toplevel is the effect's `prebuilt` passthru |
| Hercules CI effects (`runCachixDeploy`) | Pull via Cachix Deploy | CI | Agent holds the Cachix activate token | As Cachix Deploy | As Cachix Deploy |
| deploy-rs | Push over SSH | Locally by default; `remoteBuild = true` builds on the target | Whoever runs it: SSH key for `sshUser`, sudo to `user` (default root) | Not handled | Exit code; magic rollback auto-reverts if the deployer cannot reconfirm over SSH within `confirmTimeout` |
| colmena | Push over SSH (`apply`); also `apply-local` | Locally by default; `buildOnTarget` builds on the target | SSH as `targetUser` (default `root`) | `deployment.keys`: plaintext from `text`, `keyFile` or `keyCommand` (run on the deployer, e.g. `vault read`), uploaded to `/run/keys` pre- or post-activation | Exit code and log output |
| `clan machines update` | Push over SSH | On the target by default (flake source is `nix copy`'d there); `deploy.buildHost` or `--build-host` to move it | Flake checkout, nix + store, root SSH to every target, and the sops admin age key | Caller decrypts the machine's age key and activation-phase secrets and uploads them; other secrets ship encrypted in the closure | Exit code and log text; no structured result (see `clan-core-programmatic-api.md`) |
| clan `dm-pull-deploy` (clan-community, experimental) | Pull: flake references gossiped over data-mesher | On the machine (`nixos-rebuild` when a new reference arrives) | Holder of a data-mesher signing key for the file | Not described in any reachable source | Not described |

## comin

- Pull mode: "Running on a machine, it periodically polls Git repositories and deploys the NixOS configuration associated to the machine" ([readme](https://github.com/nlewo/comin/blob/f954511/readme.md)).
- Builds locally. Its feature list still has "No local evaluation mode with Niks3/Cachix pinning support" as **unchecked** ([nlewo/comin#207](https://github.com/nlewo/comin/pull/207), [docs/features.md](https://github.com/nlewo/comin/blob/f954511/docs/features.md)).
- Credentials are per-machine file paths: `remotes.*.auth.access_token_path`, `ssh_deploy_key_path`, `ssh_known_hosts_path` ([generated-module-options.md](https://github.com/nlewo/comin/blob/f954511/docs/generated-module-options.md)). The advanced-config example points `access_token_path` at a sops-nix secret.
- Trust in what it deploys comes from Git, not a central signer: optional GPG / SSH commit-signature checking (`gpgPublicKeyPaths`, `sshAllowedSignersPath`), and a commit-selection algorithm that refuses force-pushed `main` and only accepts `testing` commits on top of `main` ([docs/design.md](https://github.com/nlewo/comin/blob/f954511/docs/design.md)).
- Reporting: metrics in `internal/prometheus` (`comin_deployment_info` labelled `commit_id`, `status`; `comin_last_eval_failed`, `comin_last_build_failed`, `comin_last_deployment_failed`, `comin_need_to_reboot`), `postBuildCommand` / `postDeploymentCommand` hooks, plus build / deploy confirmers that can require a human to approve.

## NixOS `system.autoUpgrade`

- A `nixos-upgrade` systemd oneshot on a timer (`dates`, `randomizedDelaySec`, `persistent`), running `nixos-rebuild switch|boot` with `--refresh --flake ${cfg.flake}` ([auto-upgrade.nix](https://github.com/NixOS/nixpkgs/blob/nixos-unstable/nixos/modules/tasks/auto-upgrade.nix)).
- Builds on the machine. `allowReboot` + `rebootWindow` reboot when kernel / initrd changed.
- No credential handling beyond what nix and git on the machine already have (`HOME=/root`, the system ssh on `path`).
- Reporting is the unit's exit status only.
- clan once wrapped it: the `clanModules/auto-upgrade` module set `system.autoUpgrade = { flake; enable = true; dates = "02:00"; randomizedDelaySec = "45min"; }` with a deprecation warning, and was deleted with the rest of `clanModules` (`35e5f4a42`, 2025-08-14). The migration table marks it "❌ Removed" ([migrate-inventory-services.md](https://github.com/clan-lol/clan-core/blob/633df331bc48162cf1e23614d7b1f7b24f37e43f/docs/src/guides/migrations/migrate-inventory-services.md)).

## Cachix Deploy

- "There's no Nix evaluation or building done on the agent"; the agent connects to the backend over websockets and waits ([docs.cachix.org/deploy](https://docs.cachix.org/deploy/)).
- Two tokens: the agent reads `CACHIX_AGENT_TOKEN` (`cachix/src/Cachix/Deploy/Agent.hs`), the deployer reads `CACHIX_ACTIVATE_TOKEN` (`ActivateCommand.hs`) ([cachix](https://github.com/cachix/cachix/tree/8693fba/cachix/src/Cachix/Deploy)).
- The deploy spec maps agent names to store paths. The agent realises them from the agent's configured cache, adding it as an extra substituter with its public key (`Activate.hs: downloadStorePaths`, `cachesArgs`), then `nix-env -p <profile> --set` and `switch-to-configuration switch`. Previous profile path is kept for rollback, and an optional `rollbackScript` is fetched too.
- `cachix deploy activate` streams each agent's log and succeeds only if every deployment status is `Succeeded`; `--async` skips waiting.
- The central runner never holds SSH or root on machines. It holds only the right to publish a store path; each machine already trusts the cache's signing key.

## Hercules CI effects

- `runNixOS` (push): the effect script is `nix-env -p ${profile} --set ${toplevel}; ${toplevel}/bin/switch-to-configuration switch` run over `effects.ssh` ([run-nixos.nix](https://github.com/hercules-ci/hercules-ci-effects/blob/9eecf40/effects/nixos/run-nixos.nix)).
  The closure is built by the Hercules agent and copied with `nix-copy-closure` (substitutes on the destination by default); `buildOnDestination` instead ships the derivation and builds there ([call-ssh.nix](https://github.com/hercules-ci/hercules-ci-effects/blob/9eecf40/effects/ssh/call-ssh.nix)).
- Credentials: the guide puts an SSH private key in the agent's `secrets.json` and adds its public key to `users.users.root.openssh.authorizedKeys.keys` on the target ([deploy-a-nixos-machine.adoc](https://github.com/hercules-ci/hercules-ci-effects/blob/9eecf40/docs/modules/ROOT/pages/guide/deploy-a-nixos-machine.adoc)). `secretsMap` selects which agent secrets an effect may read; a `secrets.json` entry can also carry a `condition` restricting which repo / branch may use it (see the `cargoPublish` reference).
- Gating is by branch (`runIf (src.ref == "refs/heads/master")`); non-matching branches still build `dependencies` and `prebuilt`, so the toplevel is known before deploy.
- `runCachixDeploy` turns the same CI into a Cachix Deploy publisher holding only `default-cachix-activate` ([run-cachix-deploy.nix](https://github.com/hercules-ci/hercules-ci-effects/blob/9eecf40/effects/cachix-deploy/run-cachix-deploy.nix)).
- The guide notes an agent deploying its own host interrupts the deployment.

## deploy-rs

- Push. Options per profile / node ([README](https://github.com/serokell/deploy-rs/blob/1cec052/README.md)): `sshUser`, `user` (deployed as, sudo if different), `remoteBuild` (build on target, fetching from its substituters; default `false`), `fastConnection` (copy the whole closure instead of letting the node substitute).
- Safety: `autoRollback` on failed activation, and `magicRollback`, where the node rolls itself back unless the deployer reconnects and confirms within `confirmTimeout`. That gives a "the machine is still reachable" signal no pull tool has.
- No secrets support. Result is the CLI exit code.

## colmena

- Push over SSH as `deployment.targetUser`, default `"root"`; `buildOnTarget` builds on the node ([options.nix](https://github.com/zhaofengli/colmena/blob/fc7d67e/src/nix/hive/options.nix)).
- `apply-local` deploys on the host running colmena, if `allowLocalDeployment` and the hostname matches ([apply-local.md](https://github.com/zhaofengli/colmena/blob/fc7d67e/manual/src/features/apply-local.md)).
- Secrets: `deployment.keys.<name>` with `text`, `keyFile` or `keyCommand` evaluated **on the deployer**, uploaded outside the store to `/run/keys` (in-memory by default) `pre-activation` or `post-activation`, each with a `<name>-key.service` unit ([keys.md](https://github.com/zhaofengli/colmena/blob/fc7d67e/manual/src/features/keys.md)). This is the same shape as clan's activation-secret upload.

## clan-core

### What `clan machines update` does

All paths at [`633df331`](https://github.com/clan-lol/clan-core/tree/633df331bc48162cf1e23614d7b1f7b24f37e43f).

1. `clan_cli/machines/update.py: update_command` runs `run_generators(all_machines, full_closure=False)` before deploying anything, so a missing var is generated (and may prompt) on the caller, writing into the flake checkout.
2. `clan_lib/machines/update.py: run_machine_update`: if no build host is set, **the target is the build host** (`_build_host = _target_host`). It becomes root on the target, then calls `upload_secret_vars(machine, target_host_root)`.
3. `upload_sources` `nix copy`s the flake source to the build host (or `nix flake archive` with `--upload-inputs` / path inputs); the target fetches the other inputs itself.
4. `_nixos_build` runs `nix build ...#nixosConfigurations."<m>".config.system.build.toplevel` on the build host, `_copy_closure` copies to the target if different, and `_nixos_activate` does `nix-env --set`, `switch-to-configuration boot`, then `switch` under `systemd-run`, falling back to `readlink /run/current-system` to decide success after an SSH drop. The toplevel is not returned (`-> None`).
5. Unattended filtering exists only as `clan.core.deployment.requireExplicitUpdate`: a machine with it set is skipped unless named.

### How secrets reach a machine (sops backend)

- Each machine has its own age key pair. The private key is itself a sops secret in the repo, `sops/secrets/<machine>-age.key`, encrypted to the admins (`clan_lib/vars/secret_modules/sops.py: ensure_machine_key`).
- On every update, `populate_dir` **decrypts that private key on the caller** and writes it as `key.txt`, and **decrypts every `neededFor = "activation"` secret on the caller** and writes it under `activation/`; `upload` copies the directory to `clan.core.vars.sops.secretUploadDirectory` (default `/var/lib/sops-nix`).
- The NixOS side sets `sops.age.keyFile = /var/lib/sops-nix/key.txt` and maps only `users` and `services` secrets to `sops.secrets`, whose `sopsFile`s are store paths of the encrypted files (`nixosModules/clanCore/vars/secret/sops/{default,generators-to-sops}.nix`). sops-nix decrypts those on the machine during activation.
- Activation secrets are read straight from `/var/lib/sops-nix/activation/...`; nothing on the machine decrypts them.
- The experimental `age` backend added in 26.05 follows the same split: "The decrypted machine private key is uploaded for on-target decryption of users/services secrets. Activation secrets are decrypted here and uploaded as plaintext (same approach as sops backend)" (`secret_modules/age.py: populate_dir`).

### What clan ships or plans for unattended updates

- Nothing in clan-core 26.05 itself. The `auto-upgrade` clanModule was removed (above).
- [26.05 release notes](https://github.com/clan-lol/clan-core/blob/633df331bc48162cf1e23614d7b1f7b24f37e43f/docs/src/releases/26-05.md) list, new in [clan-community](https://git.clan.lol/clan/clan-community): "`dm-pull-deploy`: pull-based deployment via data-mesher".
  The [data-mesher blog post](https://clan.lol/blog/data-mesher/) calls it "an asynchronous deployment system which distributes flake references via Data Mesher", where "machines automatically run `nixos-rebuild` when a new flake reference arrives", and labels it an experiment.
  Its source could not be read here, so how it handles secrets, signing keys and reporting is unknown.
- `data-mesher` (clan-core, experimental) is the transport: gossip-replicated files, each with an allow-list of ED25519 signer keys; only signed files listed in config sync (`clanServices/data-mesher/README.md`). That gives a pull model a signed "desired revision" channel without a Git forge.

## What clan could support

`clan machines update` today needs, wherever it runs: the flake, nix + a store, root SSH to every target, and the sops admin key (for the machine key and activation secrets). Against that:

**Pull removes central root SSH.** comin, `system.autoUpgrade` and `dm-pull-deploy` all activate locally as root via a systemd unit; nobody connects in. A clan-operator in pull mode only has to publish a desired revision (Git ref, data-mesher signed file, or a Cachix-style store path) and collect status.

**Pull removes the central sops key for most secrets, not all.**

- `users` / `services` secrets already work with no admin key on the machine: they ship encrypted in the closure, encrypted to the machine's own age key, and sops-nix decrypts them with the persisted `/var/lib/sops-nix/key.txt`. A machine rebuilding itself from the flake (comin-style) gets them for free, provided `key.txt` was provisioned once (by `clan machines install` or one `update`).
- `activation` secrets break: the machine never decrypts them; they are plaintext uploads from the caller. A pull model needs either a small on-machine step that decrypts them with `key.txt` into `/var/lib/sops-nix/activation/` before switching (each deployed secret is already encrypted to its machine's age key: `SecretStore._set` passes `add_machines = policy.deploy` to `encrypt_secret`), or a rule that pull-managed machines use no activation secrets.
- Machine key creation and rotation still need the admin key, because `<machine>-age.key` is encrypted to admins and delivered by upload.
- Var **generation** stays central and needs the admin key: `run_generators` writes new encrypted vars into the repo and decrypts existing ones as generator inputs. A pull deploy can only consume vars already committed; a missing var must fail the rollout rather than be generated on the machine.

**Where to build.** Two shapes, both with prior art:

- Machine evaluates and builds (comin, autoUpgrade, `dm-pull-deploy`): needs nix + enough RAM on every node, which is the reason rosequartz's Pis already build on gaea.
- Central build, machine only fetches (Cachix Deploy, Hercules `runCachixDeploy`): the runner needs the flake, nix and cache push rights, but no SSH and no sops key, since the closure carries only encrypted secrets. Machines need only a trusted substituter (harmonia / ncps in this fleet). Activation secrets still need the on-machine decrypt step above.

**Reporting.** No tool reports more than comin and Cachix Deploy: per-machine deployed commit and status. For clan-operator the useful pair is the desired toplevel (evaluated or built centrally) against the machine's `readlink /run/current-system`, reported by the machine (comin-style metrics or a status file) rather than read over SSH.

**What push keeps.** deploy-rs's magic rollback (confirm reachability from the deployer) and colmena's / clan's pre-activation secret upload need an inbound connection; pull tools replace the first with local switch inhibitors / boot-entry fallbacks and have no equivalent for the second.
