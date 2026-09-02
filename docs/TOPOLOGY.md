# Cluster Topology

This document is the design for deciding which machines run which cairn services.
It replaces the model where a machine's `role` implies a fixed bundle of services with one where a machine declares the services it runs.
The motivating case is running etcd on its own machines, but the goal is the general one: any machine runs any combination.

Status: phase 1 is implemented.
Phases 0 and 2 through 6 are design.

## The Problem

`cairn.clusters.<name>.machines.<n>.role` is an enum of `control-plane` and `worker`.
That one value decides where six services run: `flakeModules/cluster/options.nix` computes the `control-plane` and `worker` machine sets, and etcd, apiserver, the control-plane kubelet, loadbalancer, coredns, and flux all default their `machines` list to the control-plane set.
"Control-plane machine" therefore means "runs etcd and the apiserver and a kubelet and HAProxy and CoreDNS and flux", and saying otherwise means overriding six lists by hand.

Placement is already half-solved.
Every service has a `machines` escape hatch, and the apiserver already reaches etcd over the network through clan exports rather than over localhost: `modules/service/etcd/default.nix` exports `https://<ip>:2379`, `modules/service/apiserver/default.nix` consumes it, and it lands on `services.kubernetes.apiserver.etcd.servers`.
etcd's own peer list comes from its role membership through `cairnLib.inventory.nodesOf`, which already works for an arbitrary machine set.

What blocks a dedicated etcd machine is not the option tree.
It is five co-location assumptions baked into the service modules (plus one pre-existing exports-selection bug), listed under [Co-location Assumptions](#co-location-assumptions) below.

## Summary of Decisions

- **A machine declares the services it runs.**
  The unit of placement is a capability, one per placeable clan service role, not a role that implies a bundle.
- **`role` survives as a preset.**
  It expands to a capability set and remains the readable shorthand for the common topologies.
  A per-machine `runs` list overrides the expansion outright.
- **Presets compose in plain Nix, not through option merge semantics.**
  The expansions are exposed as `inputs.cairn.lib.presets`, so a consumer writes `runs = inputs.cairn.lib.presets.control-plane ++ [ "monitoring" ]` or `lib.remove "etcd" inputs.cairn.lib.presets.control-plane`.
  There is no `alsoRuns`, no `excludes`, and no merge order to document.
- **The old surface breaks cleanly.**
  No deprecation alias and no warnings.
  `machines.<n>.schedulable` is removed, the single role tag in the inventory becomes one tag per capability, and the examples, docs, and checks move in the same change.
- **The service modules stop assuming co-location.**
  Certificates one service declares and another consumes move to shared modules, and every probe that curls `127.0.0.1` becomes conditional on the thing it probes actually being local.
  This is the bulk of the work and lands before the option tree changes.
- **Validation keys off capabilities.**
  "At least one machine has `role = \"control-plane\"`" becomes "at least one machine runs the apiserver", and version skew is computed between apiserver machines and the kubelets that are not apiservers.

## Capability Vocabulary

One capability per placeable clan service role:

`pki`, `etcd`, `apiserver`, `kubelet`, `node`, `loadbalancer`, `network`, `kubeconfig`, `inoculant`, `coredns`, `flux`

`node` is a schedulable kubelet.
It is a capability rather than a boolean so that "runs a kubelet" and "accepts pods" are stated the same way for every machine.
That retires `machines.<n>.schedulable`, which exists only to work around nixpkgs tainting a master-only machine unschedulable, and its special case in the lowering.

### Preset expansion

| Preset | Expands to |
|---|---|
| `control-plane` | pki, etcd, apiserver, kubelet, loadbalancer, coredns, flux, network, kubeconfig, inoculant |
| `worker` | pki, kubelet, node, network, kubeconfig, inoculant |
| `etcd` | pki, etcd |
| `loadbalancer` | pki, loadbalancer |

The `control-plane` and `worker` expansions reproduce today's defaults exactly, so a cluster spec that names no machine list evaluates to the same inventory it does now.
`etcd` and `loadbalancer` are the presets for the split topologies this design exists to enable.
A dedicated etcd machine deliberately runs no kubelet and no CNI: it is not a Kubernetes node, it is a machine that happens to hold the cluster's datastore.

### The override

`machines.<n>.runs` is `nullOr (listOf (enum capabilities))`, default `null`, meaning "use the preset".
When set, it *is* the machine's capability set.
Replacement rather than addition keeps a machine's capabilities readable from one line, and composition is a list operation the consumer already knows how to write.

Each service's `machines` default becomes "every machine with capability X".
The per-service `machines` lists stay as the final override, and `services.kubelet.controlPlaneMachines` and `services.kubelet.workerMachines` collapse into one `services.kubelet.machines`, with schedulability read off the `node` capability.

## Co-location Assumptions

These are what actually break when a service moves off a control-plane machine.
Each is fixed on its own, before the option tree changes.

### etcd declares a certificate the apiserver consumes

`modules/service/etcd/member.nix` declares `etcd-client-cert` (CN `kube-apiserver-etcd-client`, profile `client`, shared) and `modules/service/apiserver/control-plane.nix` reads it.
On an apiserver machine that is not an etcd member, `pki.certs."etcd-client-cert"` is a missing attribute and evaluation fails.
The certificate material is already cluster-wide, since the cert is shared; only the declaration site is wrong.

It cannot simply move to the apiserver, because etcd needs it too, for `ETCDCTL_CERT` and `ETCDCTL_KEY`.
It moves to `modules/service/etcd-client.nix`, imported by both role modules.
`modules/service/cluster.nix` is the existing instance of this pattern, and NixOS deduplicates the import by path, so a machine running both sees one declaration.

This is the assumption that makes a split topology fail to evaluate at all, so it is fixed first.

### The loadbalancer probes a local apiserver

`modules/service/loadbalancer/control-plane.nix` derives the local apiserver's port from the first backend export and curls `https://127.0.0.1:<port>/readyz` in the keepalived track script.
On a loadbalancer machine with no apiserver, the probe fails permanently, so the script's weight is applied for good and the machine never wins the VRRP election.

The role gains an `apiserverColocated` setting, lowered from whether the machine is in the apiserver's machine list, gating both the `vrrpScripts` block and `trackScripts`.
HAProxy's `/readyz` backend check is unaffected, and it is what actually drops a dead apiserver from rotation.
The keepalived track script only ever answered the narrower question of whether the VIP holder's own apiserver is healthy.

### etcd imports cluster facts it does not use

`modules/service/etcd/member.nix` imports `modules/service/cluster.nix`, which declares `vip` with no default and derives `apiServerURL` from it, though etcd uses only `clusterName`.
On a machine that runs etcd alone, `vip` has no definition, and any module that touches `apiServerURL` there fails.
The lowering compounds this by listing etcd machines in its hand-maintained "cluster scoped" set purely because of that import.

`cluster.nix` splits: `modules/service/identity.nix` declares `clusterName` alone, `cluster.nix` imports it and keeps the apiserver-facing facts, and etcd imports only the former.
Declaring `clusterName` inside the etcd role module instead would collide with `cluster.nix` on any machine running both etcd and the apiserver, since the module system rejects two declarations of one option.

### The kubelet's two roles differ by co-location

`modules/service/kubelet/worker.nix` is `common.nix` plus `roles = [ "node" ]` and a master address taken from the VIP.
The `control-plane` role is `common.nix` alone, leaning on the co-located apiserver module to set the master address.
That is the same kubelet twice, distinguished by what else happens to be on the box.

They collapse into one `kubelet` role with a `schedulable` setting, and every kubelet addresses the apiserver through the VIP.
Going through the VIP on a machine that also runs an apiserver costs one hop through local HAProxy and removes the special case.

### coredns reads the local apiserver's NixOS config

`modules/service/coredns/control-plane.nix` derives the DNS ClusterIP from `config.services.kubernetes.apiserver.serviceClusterIpRange`, and `modules/service/coredns/default.nix` takes its node list from its own role membership.
Both become explicit settings lowered from the cluster option tree, which is where the service CIDR is already known.

### Export selection ignores the instance

`lib/exports.nix` matches exports on `serviceName` and `roleName` only.
With two clusters in one clan, distinguished by `instancePrefix`, both produce `serviceName = "etcd"` and `roleName = "member"`, so one cluster's apiserver collects the other's etcd endpoints.
The predicate gains `instanceName`, and callers pass their own.

This is a bug today rather than something the new model introduces, but a design that encourages more instances makes it easier to trip.

## Validation

The "at least one machine has `role = \"control-plane\"`" check is replaced by a capability-keyed set:

- At least one machine runs `apiserver`.
- An enabled apiserver implies at least one `etcd` machine.
- An even number of etcd machines is rejected: a four-member cluster tolerates the same single failure a three-member one does, while adding a machine that must be online for writes.
- Every `apiserver` machine also runs `kubelet`, matching what `modules/service/apiserver/README.md` already documents as a requirement.

Version skew is computed from `role` today: workers are checked against the oldest pinned control-plane machine.
It rekeys onto capabilities, with the baseline taken from `apiserver` machines and checked against kubelet machines that are not apiservers.
A dedicated etcd machine drops out of the calculation entirely, which is correct, since it runs no Kubernetes component the skew policy covers.

## Labels and Tags

`nodeLabels` defaults from capabilities rather than from `role`:

- a machine running `apiserver` gets `node-role.kubernetes.io/control-plane`
- a machine running `node` but not `apiserver` gets `node-role.kubernetes.io/worker`
- a machine that is neither, such as a dedicated etcd member, gets `{ }`

The third case matters: a machine with no kubelet is not a Kubernetes node, and labelling it is meaningless, since there is no Node object to carry the label.

Inventory tags become one tag per capability plus the machine's own `tags`, replacing the single role tag.
A consumer assigning their own clan services by tag can then target `etcd` or `loadbalancer` machines directly, which the single role tag never allowed.
This breaks any consumer currently matching on the `control-plane` or `worker` tag, and it is the reason the change is grouped into the one breaking phase.

## Phased Implementation

Each phase is one pull request, independently reviewable and CI-green.
Phases 0 through 4 change no user-facing option and can land in any order.
Phase 5 is the breaking one and depends on the rest.

### Phase 0: export instance scoping

`lib/exports.nix` and its two callers.
No surface change.

### Phase 1: the shared etcd client certificate

Implemented.

`modules/service/etcd-client.nix`, imported by the etcd member and apiserver role modules, plus dropping etcd's `modules/service/cluster.nix` import.
After this phase a machine can run etcd alone, and a machine can run the apiserver without etcd.
This is the phase that unblocks everything else.

### Phase 2: loadbalancer colocation gate

`modules/service/loadbalancer/`, plus the `apiserverColocated` setting in the lowering.

### Phase 3: coredns explicit ClusterIP and node list

`modules/service/coredns/`.

### Phase 4: kubelet role collapse

`modules/service/kubelet/`, plus the `services.kubelet.machines` change in the option tree.
The two clan roles become one; this is visible to a consumer writing a hand-written inventory, so it is the one non-option-tree phase with a migration note.

### Phase 5: the capability option tree

`machines.<n>.runs`, the preset expansions, `flake.lib.presets`, capability-derived service defaults, the new validation set, capability-derived `nodeLabels` and tags, and removal of `schedulable`.
Updates `examples/ha-cluster/cluster.nix`, `docs/USAGE.md`, and `checks/flake-module.nix` in the same pull request, since the surface breaks.

### Phase 6: a split-etcd example

`examples/split-etcd/`, alongside `examples/ha-cluster/`, with the cluster spec in its own file so the flake check evaluates the same thing the example ships.

## Testing

`examples/single-node/` is the maximal co-location case: one machine runs everything, so it passes no matter how tangled the assumptions are.
It catches none of this.

The coverage that matters is a decoupled topology run through the option tree the way `checks/flake-module.nix` already runs `examples/ha-cluster/cluster.nix`.
A second cluster spec with dedicated etcd machines and an apiserver machine that is not an etcd member, forced through `nixosConfigurations` for one etcd-only machine and one apiserver machine, is the regression test for the whole effort.
Forcing the etcd-only machine catches the certificate split; forcing the apiserver machine catches the rest.

That check is written in phase 1 and fails before the fix, which is the point.

The existing assertions that encode the current topology move in phase 5: the etcd member list, the kubelet control-plane and worker split, keepalived's track scripts, the `nodeLabels` default, the machine tag list, and the forced NixOS probe, which gains the two new machine classes.

## Why Not the Alternatives

### Add `etcd` to the role enum and stop

The smallest change that satisfies the immediate request.
It does not generalize: every new topology needs another enum value, and a machine running etcd and a loadbalancer and nothing else has no name.
The enum grows one value per combination, which is the wrong shape for a combination.

### Drop `role` entirely and put placement only in the service lists

Maximally flexible and requires no new concepts, since `services.<n>.machines` already exists.
It costs the defaults that make the option tree terse: the common three-plus-two topology becomes ten hand-written machine lists, and the failure mode of forgetting one is a service silently not deployed.
The preset keeps the common case one word.

### Derive placement from clan inventory tags

Clan already has a tag mechanism, and the lowering already emits tags, so placement could read from there.
Tags are unvalidated strings, which loses the "no such machine" error the lowering raises when a service names a machine that was never declared.
That error is the option tree's most useful diagnostic and is worth more than the mechanism reuse.

### Invert the direction: per-machine service settings

Instead of each service naming its machines, each machine would carry a block of per-service settings.
This reads well for a single machine and duplicates the entire service settings surface once per machine.
It also breaks the lowering's single settings merge, where a service's `settings` attrset is applied last and wins over per-machine values.
