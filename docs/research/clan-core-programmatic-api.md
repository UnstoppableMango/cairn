# What clan-core offers a program that isn't the CLI

Research for [#143](https://github.com/UnstoppableMango/cairn/issues/143).
Question: can clan-operator's core call a library instead of shelling out to `clan machines update`, and in which language?

## Source and pinning caveat

- cairn's `flake.lock` pins clan-core `606b846f5462ec1097ccd0ca3eacbcb6c314b045` (2026-10-14), a commit on the `26.05` release branch.
- `git.clan.lol` is not reachable from this environment (proxy policy 403).
  The GitHub mirror `github.com/clan-lol/clan-core` has `main` but neither the `26.05` branch nor `606b846`.
- All citations are therefore at **`633df331bc48162cf1e23614d7b1f7b24f37e43f`** on `main` (2026-06-23, "docs: port fixes accumulated during 26.05 release"), right after `80ead27` ("docs/versions: enable 26.05", 2026-06-22).
  This is the closest reachable commit to the 26.05 branch point.
  Backports between it and `606b846` could differ in detail, but none of the conclusions depend on anything finer than function signatures.
- Paths below are relative to the clan-core root at that commit.

## Short answer

- There is no non-Python API. `clan_lib` is a Python package inside the `clan-cli` derivation (`pkgs/clan-cli/pyproject.toml`: one distribution `clan` with packages `clan_lib*` and `clan_cli*`). It has no stable or versioned contract.
- The only cross-language transport in 26.05 is **clan-app's HTTP JSON server** (`clan-app --http-api`). It is a GUI backend: localhost by default, CORS `*`, no auth, logging middleware disabled. clan-app was **removed from `main` on 2026-07-08** (`30d8ef9` "clan-app: drop for reduction effort"), so building on it means building on something upstream already dropped.
- The CLI has **no JSON output for `machines update`**. Output is human log text, and the exit code is 0 or 1.
- `run_machine_update` (library) **returns `None`**: it does not hand back the built toplevel. A cancelled run can also return `None` silently.
- The deployed state can be read back over SSH (`readlink /run/current-system`, or `nixos-rebuild list-generations --json` via `get_machine_generations`), and the desired toplevel by evaluating the flake. Neither needs clan.

Recommendation: keep the operator in **Go** and keep wrapping the **CLI** in a Job, treating the exit code as the result. Derive "what is deployed" independently: SSH `readlink /run/current-system` on the target, compared with `nix eval`/`clan select` of `nixosConfigurations.<m>.config.system.build.toplevel`. A Python core would buy a typed call into `run_machine_update`, but no richer progress, no return value, and only cooperative in-process cancellation.

## What `clan_lib` exposes

`clan_lib.api.API` is a `MethodRegistry` (`pkgs/clan-cli/clan_lib/api/__init__.py:334`).
Functions decorated `@API.register` are wrapped to return `ApiResponse = SuccessDataClass | ErrorDataClass` (`:82`), and `API.to_json_schema()` emits a JSON Schema for every method (`pkgs/clan-cli/clan_lib/api/cli.py`, `pkgs/clan-cli/openapi.py`).
The registered set at this commit is 52 functions, including:

| Area | Functions (file) |
|---|---|
| Machines | `list_machines`, `get_machine`, `set_machine`, `list_machine_state`, `get_machine_state` (`clan_lib/machines/actions.py`); `run_machine_update` (`machines/update.py`); `run_machine_install` (`machines/install.py`); `get_machine_generations` (`machines/generations.py`); `get_machine_details` (`machines/list.py`); `delete_machine`; hardware `run_machine_hardware_info_{init,update}`, `get_machine_hardware_summary` |
| Vars | `get_generators`, `run_generators`, `get_generator_prompt_previous_values` (`clan_lib/vars/generate.py`) |
| Network | `check_machine_ssh_login`, `check_machine_ssh_reachable` (`clan_lib/network/check.py`) |
| Services / inventory | `list_service_modules`, `list_service_instances`, `create/set/delete_service_instance` (`clan_lib/services/modules.py`), `list_tags`, `get_clan_details`, `check_clan_valid` |
| Tasks | `delete_task`, `list_tasks` (`clan_lib/api/tasks.py:23,57`) |
| Logs | `list_log_days`, `list_log_groups`, `get_log_file` (`clan_lib/log_manager/api.py`) |

ADR `docs/src/decisions/02-clan-as-library.md` (Accepted) states the intent, "library centric development" with CLI, GUI and a future REST API as frontends. It also says library functions "don't have to be JSON-serializable in general". No document promises stability for these signatures.

## Errors

- **Library:** the `@API.register` wrapper catches `ClanError` and returns `ErrorDataClass{op_key, status:"error", errors:[ApiError{message, description, location}]}`. Any other exception becomes `description: "An unexpected error occurred"` (`clan_lib/api/__init__.py:62,149-190`). Called directly, without the wrapper, functions raise `ClanError` / `ClanCmdError` (the latter carries the failed command's stdout, stderr and return code: `clan_lib/cmd/__init__.py`).
- **CLI:** `main()` logs a `ClanError` and exits 1. `KeyboardInterrupt` also exits 1 (`clan_cli/cli.py:504-512`). There is no error taxonomy in exit codes.
- Error strings from `update` are prose, e.g. `nix build failed for '<m>' (exit code N).` or `switch-to-configuration failed on '<m>' ... See above for details.` (`clan_lib/machines/update.py`). The detail is in the streamed log, not in the error.

## Progress

- **Structured progress exists only for install.** `clan_lib.api.message_queue` (`clan_lib/api/__init__.py:52`) is a process-global `Queue` that the webview drains. Its only producer is `notify_install_step` (`clan_lib/machines/install.py:57`). `run_machine_update` emits nothing to it.
  clan-app's UI subscribes to `"run_machine_update"` messages anyway (`pkgs/clan-app/ui/src/models/api/clan/machine.ts:359`), so its update progress label never advances.
  The queue was removed from `main` on 2026-07-08 (`31efebf` "clan-api: remove message queue").
- **Otherwise progress is log text.** Subprocess output is streamed line by line through Python `logging`, with a `[<machine>]` prefix (`clan_lib/custom_logger/__init__.py`, `PrefixFormatter`). `nix build` runs with `-L` (`update.py:30-42`). In-process, a caller can redirect per-thread stdout and stderr through `AsyncContext`; clan-app's `LoggingMiddleware` did this to tee into per-op log files. That middleware is commented out in both backends at 26.05 (`pkgs/clan-app/clan_app/app.py:99,140`).
- No phase events (build / copy / activate) are emitted. A wrapper can only infer phases from log lines.

## Cancellation

- **Cooperative, in-process, thread-scoped.** `is_async_cancelled()` reads a per-thread `should_cancel` callback (`clan_lib/async_run/__init__.py:99`). `run()`'s IO loop checks it every 0.1 s, then breaks and terminates the child: SIGTERM, then SIGKILL, to its process group, or to the process alone when `needs_user_terminal` (`clan_lib/cmd/__init__.py:117-121,194-216`).
- `delete_task(task_id)` sets the stop event of a thread registered in `BACKEND_THREADS` (`clan_lib/api/tasks.py:23`). The registry is populated only by clan-app's bridges (`pkgs/clan-app/clan_app/api/api_bridge.py:112-170`, `backends/http/http_bridge.py:351`). The GUI sends `delete_task` when an `AbortSignal` fires (`ui/src/models/api/clan/client/http.ts:21`).
- `machines update` checks cancellation after the build and after the copy (`update.py:662,692`). It **returns normally** at those points, so a wrapped call reports `status: "success"` for a run that never activated. The build itself raises `"Build cancelled"` (`update.py:303`). Activation runs under `systemd-run --pipe` on the target (`update.py:378-…`), so once it starts it is not cancelled by dropping the client.
- **CLI:** there is no cancel API. Killing the process works: SIGINT is handled, and children in their own sessions are reaped by the `terminate_process_group` context managers on unwind. SIGTERM to a Job pod gets no special handling. Activation already started on the target continues regardless, by design.

## `machines update` in detail

### Inputs

| CLI (`clan_cli/machines/update.py:236-301`) | Library `run_machine_update` (`clan_lib/machines/update.py:557`) |
|---|---|
| `MACHINE...` (none means all machines without `requireExplicitUpdate`), `--tags` | `machine: Machine{name, flake}` (one machine) |
| `--target-host user@host:port` (one machine only) | `target_host: Remote \| LocalHost` (required) |
| `--build-host` (`localhost` or ssh URI) | `build_host: Remote \| LocalHost \| None` (`None` builds on the target) |
| `--upload-inputs` | `upload_inputs: bool` |
| `--specialisation` | `specialisation: str \| None` |
| `--host-key-check`, `--no-check` (sets `NIXOS_NO_CHECK=1`) | via `Remote.host_key_check`; env var |
| common `--flake`, `--option`, `--debug` | `Flake(identifier, nix_options)` |

The CLI does more than the library function (`update_command`, `:168-229`): it runs inventory migrations, precaches selectors, runs `run_generators(all_machines, full_closure=False)` for **every** machine (`:193`), resolves the target via `get_best_remote` (network or VPN selection), then runs per-machine updates in parallel threads (`AsyncRuntime`, `:195-229`).
A program calling `run_machine_update` directly must reproduce the generator step itself. The library function only uploads already-generated secret vars (`update.py:600`). clan-app's update calls `run_machine_update` alone (`ui/src/models/api/clan/machine.ts:350-383`).

### Pipeline (NixOS)

`_update_nixos` (`update.py:637-699`) does no `nixos-rebuild`:

1. upload the flake source to the build host;
2. `nix build …#nixosConfigurations."<m>".config.system.build.toplevel` (`_nixos_build`, `:277-334`), parsing the out path from stdout;
3. `nix copy` to the target if the build host differs;
4. `nix-env -p /nix/var/nix/profiles/system --set <path>`, then `switch-to-configuration boot`, then `switch`, with one retry. A final `readlink /run/current-system` comparison catches a dropped SSH session after a successful switch (`_nixos_activate`, `:378-555`, readlink at `:539`).

### What it reports

- **During:** prefixed log lines only (see Progress).
- **After:** CLI exit 0 or 1. The library returns `None` or raises `ClanError`.
  The built toplevel path is a local variable inside `_update_nixos` and is **not returned or persisted**. Nothing is written to the inventory or git on update; `installedAt` is written only by install (`install.py:271`).

### Reading the deployed generation back

- `get_machine_generations(target_host)` runs `nixos-rebuild list-generations --json` on the target (`clan_lib/machines/generations.py:21-44`). It returns generation number, date, NixOS version, kernel, `configurationRevision`, specialisations and `current`, but **no store path**. It also needs `nixos-rebuild` on the target, and clan does not set `system.configurationRevision` (no occurrence in the tree).
- The authoritative comparison is `readlink /run/current-system` (deployed) against the evaluated `nixosConfigurations.<m>.config.system.build.toplevel` (desired). `clan select <selector>` prints any flake selector as JSON (`clan_cli/select.py:11`), the one CLI path with machine-readable output, but plain `nix eval --raw` works as well.

## What the GUI shows about machines

clan-app (Solid.js UI over the API, `pkgs/clan-app/ui`) shows per machine: name, platform (`machineClass`), description, tags, the service instances it is in, and a status badge (`ui/src/components/Sidebar/SidebarMachine/`, `components/MachineStatus`). It also has install and update wizards with a Cancel button that aborts the HTTP call.

The status badge comes from `get_machine_state` (`ui/src/models/api/clan/clan.ts:101`). The enum has `not_installed | offline | out_of_sync | online` (`clan_lib/machines/actions.py:35`), but the implementation only ever returns **`offline` if inventory `installedAt` is set, else `not_installed`** (`actions.py:225-265`, comment: "add more info later when retrieving remote state").
So the GUI has **no live reachability, no deployed-vs-desired drift, and no generation history**; `get_machine_generations` is registered but the UI never calls it.
A dashboard gets nothing for free here: drift and "last deployed" would have to be computed by the operator.

## The HTTP transport (26.05 clan-app)

- `clan-app --http-api [--http-host localhost] [--http-port …]` (`pkgs/clan-app/clan_app/__init__.py:22-35`) starts a `ThreadingHTTPServer` (`backends/http/http_server.py`) with Swagger at `/api/swagger` and `GET /api/methods`.
- Call: `POST /api/v1/<method>` with body `{"header": {"op_key": "<uuid>"}, "body": {<args>}}`. The response is `{"body": ApiResponse, "header": {}}`, sent **when the call finishes** (`backends/http/http_bridge.py:214-262,302`). There is no streaming and no job handle beyond the client-chosen `op_key`.
- Cancel: a second `POST /api/v1/delete_task {"body": {"task_id": "<op_key>"}}`.
- It still launches a webview or browser tab (`app.py`), has no auth, and sends `Access-Control-Allow-Origin: *`. It is a desktop dev backend, not a service API, and it does not exist on `main` after 2026-07-08.

## Implications for clan-operator

| Option | Gains | Costs |
|---|---|---|
| Go, `clan machines update <m>` in a Job (current scaffold) | Same code path users run, including generators, migrations and network selection; language unchanged; process isolation; cancel by deleting the pod | Logs only; result is the exit code; parse nothing |
| Python, import `clan_lib` | Typed inputs, `ClanError` messages, in-process cancel flag | Must re-implement `update_command`'s pre-steps; no return value; silent "success" on cancel; private, unversioned API; ties the operator to clan-cli's Python env |
| Go to clan-app HTTP | JSON envelope, `delete_task` | Dropped upstream after 26.05; GUI-oriented; no auth; still no progress or return value |

Whichever is chosen, the operator should own deployed-state observation itself (SSH `readlink /run/current-system`, evaluated toplevel). clan-core offers no status a dashboard could reuse.
