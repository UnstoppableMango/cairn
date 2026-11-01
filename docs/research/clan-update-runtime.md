# What `clan machines update` needs at runtime

Research for cairn issue #131.
The question: where does `clan machines update <machine>` evaluate a machine's NixOS configuration, and what must be present wherever the command runs?
The answer decides whether the phase 4 operator in `docs/UPGRADES.md` can run in a pod that "never evaluates nix and never sees the flake" and "needs no nix store" (`docs/UPGRADES.md:177`, `docs/UPGRADES.md:184`).

**Short answer: the claim is refuted.**
The clan CLI reads the flake source itself.
It evaluates the flake with a local `nix` against a local store, including parts of the NixOS config of every machine in the clan.
It decrypts the sops-encrypted machine age key and activation secrets with a local age identity.
It copies the flake source out of its local store to the build host.
Building on the target only moves the evaluation and build of `system.build.toplevel`.

## Sources and revision

cairn's `flake.lock` pins clan-core `606b846f5462ec1097ccd0ca3eacbcb6c314b045`, the 26.05 release branch, last modified 2026-10-14 (`/home/claude/cairn/flake.lock`, node `clan-core`).
That commit exists only on git.clan.lol, which this session could not reach, and the GitHub mirror (`github.com/clan-lol/clan-core`) has no 26.05 branch (`upload-pack: not our ref`).
The code here was read at two `main` commits on the mirror, one on each side of the pinned commit:

- **Base:** `80ead2786c719b0eafa88fde3a944b2ece9cbd28` (2026-06-22, "docs/versions: enable 26.05"), the point where `main` turned on 26.05 docs. Line numbers below refer to this commit.
- **Head:** `dbae21013aca57424620d06863cbfd2e4107352b` (2026-10-26), twelve days after the pinned commit.

Between the two, the files involved changed only cosmetically (`git diff --stat 80ead27 dbae210`): an inventory-migration call, forwarding `forwardAgent` on CLI overrides, a lazy-trees fallback for the flake store path (`_flake_store_path`), and vars directory naming (`rel_dir`).
The build, copy and activate pipeline, the local evaluation and the secret upload are the same in both.
The release branch could carry backports that differ from both, but nothing in these diffs suggests it.

Links use `https://github.com/clan-lol/clan-core/blob/80ead2786c719b0eafa88fde3a944b2ece9cbd28/<path>#L<a>-L<b>`. Paths below are relative to the repo root, and `cli/` is short for `pkgs/clan-cli/`.

## 1. The pipeline, step by step

`clan machines update` is `update_command` in `cli/clan_cli/machines/update.py:168-233`.

1. **Opens the flake locally.** `require_flake(args.flake)` (`:172`). Every later `select` goes through `Flake.prefetch`, which runs `nix flake prefetch --json <identifier>` locally to put the flake into the local store (`cli/clan_lib/flake/flake.py:909-950`).
1. **Picks the machines** (`get_machines_for_update`, `:106-165`). With no machine names given, it filters every machine through `requires_explicit_update` (`:86-103`). With names given, it uses those machines and does not consult `requireExplicitUpdate` at all (`:152-165`). See section 5.
1. **Precaches selectors for every machine in the clan**, not only the ones being updated (`:183-191`). The selectors are the vars generators' metadata and files, sops settings and upload directory, and `requireExplicitUpdate` (`cli/clan_lib/vars/generator.py:153-179`, `cli/clan_lib/nix_selectors.py:198-265`). They all read `clanInternals.machines.<system>.<machine>.config.…` (`nix_selectors.py:17`), the evaluated NixOS module tree of each machine, where `<system>` is the *local* `nix config` system (`update.py:180-181`).
1. **Runs vars generators** for all machines (`run_generators(all_machines, full_closure=False)`, `:193`). This runs vars migrations on the clan directory (`cli/clan_lib/vars/generate.py:297-300`), health-checks the sops store against the current recipients (`generate.py:193-218, 323-325`; `cli/clan_lib/vars/secret_modules/sops.py:132-172`), and generates and writes any missing vars, prompting if needed (`generate.py:304-321`).
1. **Resolves the build host**: `--build-host` (with `localhost` meaning `LocalHost`), else the machine's configured build host (`update.py:197-208`). See section 3.
1. **Resolves the target host**: `--target-host`, else `get_best_remote` (`update.py:60-83`). See section 4.
1. **Runs `run_machine_update`** (`cli/clan_lib/machines/update.py:557-634`):
   1. Opens SSH ControlMaster connections to the target and, if separate, the build host (`:583-594`). With no build host, **the build host is the target** (`:588-590`).
   1. Becomes root on the target (`:597`).
   1. **Uploads secret vars to the target** (`upload_secret_vars`, `:600`). See section 6.
   1. Gets the flake source to the build host. For a remote build host that is `upload_sources` (`:605-606`). For a local one it reads the local flake's store path (`:607-613`).
   1. Runs `_update_nixos` (`:637-698`): build, copy the closure if needed, activate.

## 2. Where the NixOS configuration is evaluated

There are two evaluations, in two places.

**On the machine running `clan` (always).**
`Flake.get_from_nix` writes a Nix expression that does `builtins.getFlake "path:<store path>?narHash=…"` and applies the selectors to it. It wraps the result in a trivial `/bin/sh` derivation with `preferLocalBuild = true` and builds it with a local `nix build --expr` (`cli/clan_lib/flake/flake.py:992-1112`, the expression at `:1037-1070`, the build at `:1075-1078`).
Those selectors reach into `config.clan.core.vars.*`, `config.clan.core.networking.*` and `config.clan.deployment.requireExplicitUpdate` of every machine (section 1, step 3). So the CLI host evaluates each machine's NixOS module system far enough to answer them.
That needs every flake input the module system touches, nixpkgs included, fetched into the CLI host's store.
It also needs a store that can build a derivation, which means a nix daemon or a writable single-user store.
clan's own docs say the same: "By default, `clan machines update <machine>` evaluates your flake on your workstation, then builds and activates on `deploy.targetHost`" (`docs/src/guides/build-host.md:11`); "Clan evaluates your flake on your workstation before any build or deploy happens" (`docs/src/guides/private-inputs.md:11`).

**On the build host (the target, by default).**
`_nixos_build` runs `nix build '<flake store path>#nixosConfigurations."<machine>".config.system.build.toplevel'` *on the build host*: `build_host.run(cmd, …)` (`cli/clan_lib/machines/update.py:277-334`, the attribute at `:287`, the run at `:292-301`).
`nix build` of a flake attribute evaluates it, so the full toplevel evaluation happens on the build host.
When building on the target, clan runs this as root on the target (`:648-652`).
The docs' "Evaluation still runs locally, but the build runs on a separate host" (`build-host.md:11`) is true of the selector evaluation but not of the toplevel, which the build host evaluates again from scratch.

**So evaluation can, and by default does, happen on the target.**
The target needs the flake source in its store (uploaded by clan) and every flake input. The fast path uploads only the flake's own source: "Just copy the flake to the remote machine, we can substitute other inputs there" (`update.py:211-239`). The target therefore fetches nixpkgs, clan-core, kubepkgs and the rest itself, from their origins or from substituters.
`--upload-inputs`, or any `path:`/`git+file:` input, switches to `nix flake archive --to ssh://…`, which pushes every input from the CLI host's store instead (`update.py:241-274`; flag at `cli/clan_cli/machines/update.py:275-283`).
A build failure that mentions fetching an input suggests `--upload-inputs` (`update.py:308-314`).
(`private-inputs.md:11` says the build and target hosts "never see the private URL". That holds only on the archive path, since the fast path copies just the top-level source.)

## 3. `--build-host`

Resolution order, highest first: `--build-host`, `inventory.machines.<name>.deploy.buildHost`, `clan.core.networking.buildHost` in the machine config, else the target (`docs/src/guides/build-host.md:72-79`; code at `cli/clan_cli/machines/update.py:197-208`, `cli/clan_lib/machines/machines.py:122-135, 175-210`; option at `nixosModules/clanCore/networking.nix:40-54`).

- `--build-host localhost` gives `LocalHost` (`cli/clan_cli/machines/update.py:200-201`). The toplevel is evaluated and built on the CLI host, then pushed with `nix copy --to ssh-ng://<target> --no-check-sigs` from there (`update.py:337-375`). This is the opposite of what the operator wants: a full store and the build happen in the pod.
- A remote build host gets the flake source from the CLI host's store (section 2). It evaluates and builds, then opens **its own** SSH connection to the target to copy the closure. That needs a key on the build host that the target accepts, or agent forwarding, plus a `known_hosts` entry there (`update.py:65-177, 665-690`; `build-host.md:82-92`).
- Architectures must match. `nix build` on the build host builds for its own system (`build-host.md:21-23`).

## 4. `--target-host` and reaching the target

- `--target-host user@host:port` connects directly and skips network discovery (`cli/clan_cli/machines/update.py:60-72`). It is allowed only with a single machine (`:175-177`).
- Otherwise `get_best_remote` uses `inventory.machines.<name>.deploy.targetHost` if set. Failing that, it tries the clan's configured networks (zerotier, tor, …) by priority, pinging each. Last, it falls back to `clan.core.networking.targetHost` from the machine config (`cli/clan_lib/network/network.py:202-262`, option at `nixosModules/clanCore/networking.nix:11-39`). cairn sets the machine-config option, `targetHost = "root@${ip}"` (`flakeModules/cluster/plan.nix:14-41`).
- Transport is the `ssh` binary on the CLI host with ControlMaster multiplexing (`cli/clan_lib/ssh/remote.py:143-176, 382, 410-433`). The CLI host needs an SSH identity the target accepts and a `known_hosts` entry, or `--host-key-check accept-new`/`none` (`cli/clan_cli/machines/update.py:255-260`).
- Root on the target is required: `become_root` uses sudo with an askpass proxy when the SSH user is not root (`cli/clan_lib/machines/update.py:596-597`; `remote.py:195-196`). It is needed for the secret upload, `nix-env -p /nix/var/nix/profiles/system --set` and `switch-to-configuration` (`update.py:378-554`).
- Activation runs `switch-to-configuration boot`, then `switch`, under `systemd-run --pipe` so it survives an SSH drop. Inhibitor failures are reported, not retried, and other failures are retried once (`update.py:378-554`). This is the "boot-first activation" `docs/UPGRADES.md:183` relies on, and it is accurate.

## 5. `requireExplicitUpdate`

- Option: `clan.core.deployment.requireExplicitUpdate`, bool, default `false`, "Do not update this machine when running `clan machines update` without any machines specified" (`nixosModules/clanCore/networking.nix:90-100`). `clan.deployment` is a renamed alias (`:120-130`), and the CLI selects through that alias (`cli/clan_lib/nix_selectors.py:263-265`).
- Effect: it only matters when no machine names are given. Then `requires_explicit_update` drops machines with the flag set, or with no resolvable target host (`cli/clan_cli/machines/update.py:86-103, 122-150`). Note the name is inverted: the function returns `True` for machines that should be updated. `--tags` alone also counts as implicit (`:121-122`).
- Naming a machine (`clan machines update pik8s7`) bypasses the flag entirely (`:152-165`). It is a guard against bulk updates, not an access control, so it does not stop an operator, or anyone else, from updating a named machine.
- Evaluating the flag is itself a local NixOS-config evaluation of every machine (section 1, step 3).

## 6. How vars and secrets reach the target

- The secret store is chosen by evaluating `clanInternals.vars.settings.secretModule` locally (`cli/clan_lib/flake/flake.py:905-907`). cairn uses the default, sops.
- `upload_secret_vars` collects the machine's generators and the flake-level generators, then calls the store's `upload` for phases `activation`, `users` and `services` (`cli/clan_lib/vars/upload.py:12-22`).
- The sops `populate_dir` (`cli/clan_lib/vars/secret_modules/sops.py:241-294`) does two things:
  - It **decrypts `sops/secrets/<machine>-age.key` locally** and writes it as `key.txt` (`:248-259`). This is the machine's own age private key.
  - It **decrypts every `neededFor = "activation"` secret locally** and writes it under `activation/<generator>/<file>` (`:261-278`; values from `decrypt_secret_raw`, `:221`).
- `upload` tars that directory with root-only permissions and extracts it on the target into `clan.core.vars.sops.secretUploadDirectory`, default `/var/lib/sops-nix` (`sops.py:301-315`; `cli/clan_lib/ssh/upload.py:14-60`; `nixosModules/clanCore/vars/secret/sops/default.nix:15-24`).
- Every other secret travels **encrypted inside the system closure**. Each var becomes a `sops.secrets` entry whose `sopsFile` is a `builtins.path` copy of the encrypted file from the flake source (`nixosModules/clanCore/vars/secret/sops/generators-to-sops.nix:66-73`). sops-nix decrypts it on the target at activation with `age.keyFile = <secretUploadDirectory>/key.txt` (`sops/default.nix:41-57`).
- Decryption on the CLI host uses the user's age identity: `SOPS_AGE_KEY`, else `SOPS_AGE_KEY_FILE`, else `~/.config/sops/age/keys.txt` (`cli/clan_cli/secrets/sops.py:91-120, 440-443`). That identity must be a recipient of every machine's `<machine>-age.key`, which in practice makes it a clan admin key.
- The sops health check runs before any of this, over all machines (section 1, step 4). It fails the update if recipients changed and secrets were not re-encrypted (`sops.py:132-172`).
- Generating a missing var writes it into the flake's `vars/` and `sops/` directories (`generate.py:342-…`). That needs a writable checkout and the generator's inputs, including interactive prompts. With every var already generated, `full_closure=False` runs nothing (`generate.py:302-308`), but the health check and the sops decryption above still run.

## 7. Requirements wherever `clan` runs

| Requirement | Needed? | Why (source) |
| --- | --- | --- |
| The `clan` CLI and its runtime (Python, `ssh`, `sops`/`age`, `nix`) | Yes | All of the above |
| The flake source | Yes, as a local path or a fetchable flake ref | `require_flake`, `nix flake prefetch` (`flake.py:909-950`). Vars generation needs a writable local checkout. |
| A Nix store that can evaluate and build | Yes | Selector evaluation is a local `nix build --expr` (`flake.py:1037-1078`). `upload_sources` does `nix copy`/`nix flake archive` *from* the local store (`update.py:211-274`). |
| All flake inputs fetchable from the CLI host | Yes | Evaluating `clanInternals.machines.*.config` needs nixpkgs, clan-core and every module input |
| A nix daemon specifically | Only if the store is not writable by the user | Any working local store will do |
| An age identity able to decrypt `<machine>-age.key` and activation secrets | Yes, with the sops backend | `sops.py:248-278`, key lookup `cli/clan_cli/secrets/sops.py:91-120` |
| SSH to the target as root, or sudo | Yes | Secret upload, profile set, activation (`update.py:596-600, 378-554`) |
| SSH from the build host to the target | Only with a separate remote build host | `update.py:665-690` |
| Network reach to the target | Yes | Over the clan network module, if any (`network.py:202-262`) |
| Network reach to substituters/input origins | **From the target** (or build host), in the default fast path | `update.py:211-212`. From the CLI host too, to fetch inputs for local evaluation. With `--upload-inputs`, only the CLI host. |
| A large store and build capacity on the CLI host | No, unless `--build-host localhost` | The toplevel builds on the build host (`update.py:287-301`) |

## Implications for the operator

- **"Never evaluates nix and never sees the flake" is false for any operator that runs `clan machines update`.** The pod needs the flake, a working `nix` with a store, and every input fetched locally, because clan evaluates the NixOS config of every machine in the clan just to pick and prepare one (sections 1 and 2). The `ClusterUpgrade` spec can carry the plan, but clan itself cannot work from the plan alone.
- **"Needs no nix store because builds happen on the target" is half right.** The toplevel is evaluated and built on the target by default, so the pod needs no build capacity and no system closures. It still needs a store big enough for the flake source and the evaluation inputs (nixpkgs, clan-core, kubepkgs, …), and a store or daemon that can realise trivial derivations.
- **The credential surface is larger than root SSH plus pre-generated vars.** The pod needs an age identity that decrypts every machine's `<machine>-age.key`, which is effectively a clan admin key. Even with every var pre-generated, `upload_secret_vars` decrypts with it on every update (section 6). A `command=`-forced SSH key on the targets does not help either, since clan runs arbitrary commands over that connection (`test`, `nix-env`, `systemd-run`, a tar extract, and the `nix copy` remote protocol).
- **`requireExplicitUpdate` is not a gate against the operator.** It only filters bulk runs, and the operator names machines (section 5).
- **Ways to keep nix out of the pod**, none of them free:
  1. Run the operator's deploy step on a machine that already has nix and the flake, such as a NixOS host acting as a dedicated runner, with the pod only orchestrating. This keeps the CLI's requirements but moves them out of the pod.
  1. Skip `clan machines update` and reimplement its last mile. Ship a pre-evaluated toplevel store path in the CRD (evaluated where the flake lives), `nix copy` it from a cache to the target, upload the secret tarball, then `nix-env --set` and `switch-to-configuration boot`/`switch` as in `update.py:378-554`. The pod then needs no flake and no evaluation, but it still holds decrypted secret material or a pre-built secret bundle, and it duplicates clan's transport, which `docs/UPGRADES.md:29, 60` rejects.
  1. Have the target pull and activate its own configuration. That is the inverted trust model `docs/UPGRADES.md:60` already rejects.
- `docs/UPGRADES.md:177` and `:184` should be corrected, and the credential paragraph at `:186-190` should add the sops admin age key and the local evaluation inputs to what the pod would hold.
