# Prior Art: Controllers That Upgrade Their Own Host

Research for [#133](https://github.com/UnstoppableMango/cairn/issues/133).
The question: how do Cluster API's KubeadmControlPlane (KCP) controller, Rancher's system-upgrade-controller (SUC) and kured handle upgrading the node or control plane they run on, and which of their patterns fit the phase 4 operator in [`docs/UPGRADES.md`](../UPGRADES.md)?
That operator's deploy step is an out-of-cluster `clan machines update <machine>` that may restart etcd and the kube-apiserver beneath it.

Every claim below cites source code or first-party docs, pinned to a release:

| Project | Release | Commit |
| --- | --- | --- |
| Cluster API | [`v1.14.3`](https://github.com/kubernetes-sigs/cluster-api/tree/v1.14.3) | `825a79dc92ddcca6acc935e233201c697a2f7488` |
| system-upgrade-controller | [`v0.20.2`](https://github.com/rancher/system-upgrade-controller/tree/v0.20.2) | `96eced818739186f46a0ce1e343fe0aed6d499c7` |
| k3s-upgrade (SUC's k3s payload) | `v1.37.1+k3s1` | [`9cf272d6`](https://github.com/k3s-io/k3s-upgrade/tree/9cf272d6186367ad80b61b343f74ab807b04fc01) |
| kured | [`1.23.0`](https://github.com/kubereboot/kured/tree/1.23.0) | `ef3c90b2bd58c0571e6eae7b893f0de3709cc98f` |

Abbreviations for links: `CAPI` = `https://github.com/kubernetes-sigs/cluster-api/blob/v1.14.3`, `SUC` = `https://github.com/rancher/system-upgrade-controller/blob/v0.20.2`, `KURED` = `https://github.com/kubereboot/kured/blob/1.23.0`.
The links are written out in full.

## Summary

| | KCP | SUC | kured |
| --- | --- | --- | --- |
| Who acts on the node | Infrastructure provider replaces the Machine, or a runtime extension updates it in place | A privileged Job pod on the target node | The DaemonSet pod on the target node reboots its own host |
| Runs on the node it upgrades? | Only in a "self-hosted" management cluster | Yes, on control-plane nodes | Yes, every node |
| Serialization | Leader election plus "one operation at a time" preflight checks | Leader election plus `concurrency` and `status.applying` | No leader: a lock annotation on the DaemonSet |
| Progress kept in | The API: Machine objects, their annotations and conditions, recomputed every reconcile | `Plan.status.applying`, Job objects, and a hash label on each node | The DaemonSet lock annotation (holder, `Unschedulable` before cordon) |
| Cordon and drain | Machine controller, before infrastructure deletion | Init containers in the Job, before the upgrade container | The agent, after acquiring the lock |
| etcd quorum | Explicit: health of every other member, fault-tolerance math, leadership moved off the leaving member | None built in; control-plane plan at `concurrency: 1` and a prepare step ordering agents after servers | None |
| Status | Conditions (`Available`, `RollingOut`, `EtcdClusterHealthy`, ...), replica counts, `version` | Conditions (`LatestResolved`, `Validated`, `Complete`), `latestHash`, `applying` | Node annotations and a Prometheus gauge; no CRD |

The common thread: none of the three keeps a progress cursor in the controller's memory.
Each one derives "what is left to do" from durable objects in the cluster on every pass, and each makes its per-node step idempotent or detectably complete, so the controller dying mid-step only delays the rollout.

## Cluster API: KubeadmControlPlane

### Where it runs

KCP normally runs in a separate management cluster, so a workload-cluster control-plane upgrade never touches the controller's own host.
The Cluster API book also describes a "self-hosted" model in which the providers manage the lifecycle of the management cluster itself ([versions.md L470-L477](https://github.com/kubernetes-sigs/cluster-api/blob/v1.14.3/docs/book/src/reference/versions.md#L470-L477)).
That self-hosted case is the one comparable to cairn.

### Leader election and handoff

- The KCP manager is a controller-runtime manager with Lease-based leader election (`--leader-elect`, lease duration 1m, renew deadline 40s, retry period 5s), lease ID `kubeadm-control-plane-manager-leader-election-capi` ([main.go L132-L142](https://github.com/kubernetes-sigs/cluster-api/blob/v1.14.3/controlplane/kubeadm/main.go#L132-L142), [L288-L293](https://github.com/kubernetes-sigs/cluster-api/blob/v1.14.3/controlplane/kubeadm/main.go#L288-L293)).
- The shipped Deployment sets `--leader-elect`, `replicas: 1`, and tolerates the control-plane taint ([manager.yaml L12, L22, L67-L71](https://github.com/kubernetes-sigs/cluster-api/blob/v1.14.3/controlplane/kubeadm/config/manager/manager.yaml#L12-L71)).
- When controller-runtime loses the lease, the manager's `OnStoppedLeading` sends `leader election lost` to its error channel and the manager stops ([controller-runtime v0.24.1 internal.go L627-L637](https://github.com/kubernetes-sigs/controller-runtime/blob/v0.24.1/pkg/manager/internal.go#L627-L637)).
  A process that can't renew because its apiserver is down exits rather than continuing as a stale leader.

There is no explicit "move the operator off the machine" step.
In a self-hosted cluster the KCP pod leaves an old control-plane machine the same way every other pod does: the Machine controller drains the node before deleting it (below).
The pod is rescheduled, and the new process takes the Lease once the old holder releases it or its lease expires.
This is an inference from the drain-then-delete sequence and the single-replica, leader-elected Deployment.
The KCP code has no special case for its own pod.
**`docs/UPGRADES.md` phase 4 says "leader election moves the operator off the machine being updated". That is not quite what KCP does.** Leader election only guarantees a single actor. Drain is what moves the pod.

### Rollout progress across restarts

KCP is level-triggered and keeps no cursor:

- Each reconcile recomputes `MachinesNeedingRollout()` by comparing every Machine against the KCP spec, then calls `updateControlPlane` ([kubeadmcontrolplane_controller.go L531-L546](https://github.com/kubernetes-sigs/cluster-api/blob/v1.14.3/controlplane/kubeadm/reconcilers/kubeadmcontrolplane/kubeadmcontrolplane_controller.go#L531-L546)).
- The reconcile is ordered so that in-flight work finishes before new work starts: sync Machines, refresh conditions, reconcile etcd members, run the pre-terminate hook on deleting Machines, finish triggering any half-started in-place update, remediate, wait for any in-place update in progress, and only then roll out ([L466-L528](https://github.com/kubernetes-sigs/cluster-api/blob/v1.14.3/controlplane/kubeadm/reconcilers/kubeadmcontrolplane/kubeadmcontrolplane_controller.go#L466-L528)).
- With the default `maxSurge: 1` ([kubeadm_control_plane_types.go L619-L626](https://github.com/kubernetes-sigs/cluster-api/blob/v1.14.3/api/controlplane/kubeadm/v1beta2/kubeadm_control_plane_types.go#L619-L626)), a rolling update first scales up a new Machine, then deletes an outdated one ([update.go L104-L173](https://github.com/kubernetes-sigs/cluster-api/blob/v1.14.3/controlplane/kubeadm/reconcilers/kubeadmcontrolplane/update.go#L104-L173)).
  A Machine with a deletion timestamp is itself the record that "this step is in progress".
- In-place updates (feature-gated) persist intent as annotations before acting.
  "Once we write UpdateInProgressAnnotation we will always continue with the in-place update" ([inplace_trigger.go L47](https://github.com/kubernetes-sigs/cluster-api/blob/v1.14.3/controlplane/kubeadm/reconcilers/kubeadmcontrolplane/inplace_trigger.go#L47)), and a later reconcile completes a trigger that failed halfway ([controller L500-L510](https://github.com/kubernetes-sigs/cluster-api/blob/v1.14.3/controlplane/kubeadm/reconcilers/kubeadmcontrolplane/kubeadmcontrolplane_controller.go#L500-L510)).
  The annotation is `in-place-updates.internal.cluster.x-k8s.io/update-in-progress` ([machine_types.go L100](https://github.com/kubernetes-sigs/cluster-api/blob/v1.14.3/api/core/v1beta2/machine_types.go#L100)).
- The external `UpdateMachine` hook that does the actual in-place work "must be idempotent - it can be called multiple times for the same Machine". It reports progress by returning `Success` with `RetryAfterSeconds > 0` until it is done ([inplaceupdate_types.go L197-L213, L244-L253](https://github.com/kubernetes-sigs/cluster-api/blob/v1.14.3/api/runtime/hooks/v1alpha1/inplaceupdate_types.go#L197-L253)).
  KCP only tries an in-place update where it would otherwise delete a Machine, and the proposal treats an in-place update as always potentially disruptive, so the Machine counts as unavailable ([update.go L141-L144](https://github.com/kubernetes-sigs/cluster-api/blob/v1.14.3/controlplane/kubeadm/reconcilers/kubeadmcontrolplane/update.go#L141-L144), [in-place proposal L292](https://github.com/kubernetes-sigs/cluster-api/blob/v1.14.3/docs/proposals/20240807-in-place-updates.md?plain=1#L292)).
- Remediation records itself in the `controlplane.cluster.x-k8s.io/remediation-in-progress` annotation and `status.lastRemediation` ([kubeadm_control_plane_types.go L53](https://github.com/kubernetes-sigs/cluster-api/blob/v1.14.3/api/controlplane/kubeadm/v1beta2/kubeadm_control_plane_types.go#L53), status struct from [L698](https://github.com/kubernetes-sigs/cluster-api/blob/v1.14.3/api/controlplane/kubeadm/v1beta2/kubeadm_control_plane_types.go#L698)).

### Cordon and drain ordering

The Machine controller, not KCP, cordons and drains.
On deletion it drains the node (if allowed), waits for volumes to detach, then waits for `pre-terminate.delete.hook.machine.cluster.x-k8s.io/*` hooks before deleting the infrastructure ([machine_controller.go L524-L624](https://github.com/kubernetes-sigs/cluster-api/blob/v1.14.3/core/reconcilers/machine/machine_controller.go#L524-L624)).
Drain timestamps persist in `status.deletion` (`nodeDrainStartTime`, `waitForNodeVolumeDetachStartTime`) so the timeouts survive restarts ([machine_types.go L728-L741](https://github.com/kubernetes-sigs/cluster-api/blob/v1.14.3/api/core/v1beta2/machine_types.go#L728-L741)).

KCP hooks into that sequence with its own pre-terminate hook, `kcp-cleanup` ([kubeadm_control_plane_types.go L66](https://github.com/kubernetes-sigs/cluster-api/blob/v1.14.3/api/controlplane/kubeadm/v1beta2/kubeadm_control_plane_types.go#L66)).
It removes the etcd member only once the Machine reports `WaitingForPreTerminateHook`, meaning drain and volume detach are done.
It handles one deleting Machine at a time, the one with the oldest deletion timestamp, "to keep this function deterministic / reentrant".
It runs last among pre-terminate hooks so the kubelet keeps working while the others run ([kubeadmcontrolplane_controller.go L1404-L1450](https://github.com/kubernetes-sigs/cluster-api/blob/v1.14.3/controlplane/kubeadm/reconcilers/kubeadmcontrolplane/kubeadmcontrolplane_controller.go#L1404-L1450)).

### etcd quorum protection

- **Preflight checks ("one operation at a time").**
  No in-place update, scale-up or scale-down starts while any Machine is deleting, or while any API server, controller-manager, scheduler, etcd pod or etcd member condition on another Machine is False or Unknown.
  The Machine being removed is excluded from the check ([preflight.go L61-L163, L166-L220](https://github.com/kubernetes-sigs/cluster-api/blob/v1.14.3/controlplane/kubeadm/reconcilers/kubeadmcontrolplane/preflight.go#L61-L220); scale-down call site [scale.go L111-L123](https://github.com/kubernetes-sigs/cluster-api/blob/v1.14.3/controlplane/kubeadm/reconcilers/kubeadmcontrolplane/scale.go#L111-L123)).
  This is the same shape as cairn's pre-gate, which excludes the target ([rollout.go `preGate`](../../pkg/upgrade/rollout.go)).
- **Leadership forwarding.**
  Before deleting a Machine that hosts the etcd leader, KCP moves leadership to another member and refuses to proceed if it can't ([scale.go L137-L148](https://github.com/kubernetes-sigs/cluster-api/blob/v1.14.3/controlplane/kubeadm/reconcilers/kubeadmcontrolplane/scale.go#L137-L148), [kubeadmcontrolplane_controller.go L1613-L1650](https://github.com/kubernetes-sigs/cluster-api/blob/v1.14.3/controlplane/kubeadm/reconcilers/kubeadmcontrolplane/kubeadmcontrolplane_controller.go#L1613-L1650)).
- **Fault-tolerance math for remediation.**
  `targetEtcdClusterHealthy` asks whether the cluster after the change still tolerates its failing members: a 3-member cluster tolerates no extra failure, a 5-member cluster one ([remediation.go L655-L677](https://github.com/kubernetes-sigs/cluster-api/blob/v1.14.3/controlplane/kubeadm/reconcilers/kubeadmcontrolplane/remediation.go#L655-L677)).
  If the answer is no, it skips remediation and says so on the Machine ([L303-L310](https://github.com/kubernetes-sigs/cluster-api/blob/v1.14.3/controlplane/kubeadm/reconcilers/kubeadmcontrolplane/remediation.go#L303-L310)).

### Status and conditions

KCP conditions include `Available`, `Initialized`, `CertificatesAvailable`, `EtcdClusterHealthy`, `ControlPlaneComponentsHealthy`, `MachinesReady`, `MachinesUpToDate`, `RollingOut`, `ScalingUp`, `ScalingDown`, `Remediating` and `Deleting`.
A blocking preflight check surfaces in the `ScalingUp`/`ScalingDown` messages ([kubeadm_control_plane_types.go L88-L327](https://github.com/kubernetes-sigs/cluster-api/blob/v1.14.3/api/controlplane/kubeadm/v1beta2/kubeadm_control_plane_types.go#L88-L327)).
Per-Machine conditions include `APIServerPodHealthy`, `EtcdPodHealthy` and `EtcdMemberHealthy` ([L355-L397](https://github.com/kubernetes-sigs/cluster-api/blob/v1.14.3/api/controlplane/kubeadm/v1beta2/kubeadm_control_plane_types.go#L355-L397)).
The status also carries `replicas`, `readyReplicas`, `availableReplicas`, `upToDateReplicas`, `version`, `observedGeneration` and `lastRemediation` ([L698 onward](https://github.com/kubernetes-sigs/cluster-api/blob/v1.14.3/api/controlplane/kubeadm/v1beta2/kubeadm_control_plane_types.go#L698)).
Failed preflight checks also emit a `ControlPlaneUnhealthy` warning event ([preflight.go L273-L292](https://github.com/kubernetes-sigs/cluster-api/blob/v1.14.3/controlplane/kubeadm/reconcilers/kubeadmcontrolplane/preflight.go#L273-L292)).

## Rancher system-upgrade-controller

### Where it runs, and leader election

- The controller is a Deployment with no `replicas` (so 1) and `strategy: Recreate`.
  It is pinned to control-plane nodes by required node affinity, uses pod anti-affinity on hostname, and tolerates the control-plane and etcd taints ([manifest L33-L81](https://github.com/rancher/system-upgrade-controller/blob/v0.20.2/manifests/system-upgrade-controller.yaml#L33-L81)).
  It therefore runs on exactly the nodes a k3s server plan upgrades.
- Leader election is on by default (`SYSTEM_UPGRADE_CONTROLLER_LEADER_ELECT: "true"`, [manifest L22](https://github.com/rancher/system-upgrade-controller/blob/v0.20.2/manifests/system-upgrade-controller.yaml#L22); flag at [main.go L43-L47](https://github.com/rancher/system-upgrade-controller/blob/v0.20.2/main.go#L43-L47)) via wrangler's `leader.RunOrDie` ([controller.go L174-L176](https://github.com/rancher/system-upgrade-controller/blob/v0.20.2/pkg/upgrade/controller.go#L174-L176)).
  Wrangler uses a Lease lock with a 45s default lease and calls `logrus.Fatalf("leaderelection lost ...")` when it loses it ([wrangler v3.8.0-rc.1 leader.go L22, L47, L63-L80](https://github.com/rancher/wrangler/blob/v3.8.0-rc.1/pkg/leader/leader.go#L22-L80)), so the process exits and the pod restarts.

### Keeping the controller out of the critical path

The controller never performs the upgrade itself.
For each selected node it creates a Job pinned to that node: `HostPID`, privileged with `CAP_SYS_BOOT`, the host root mounted at `/host` ([job.go L184-L260, L448-L470](https://github.com/rancher/system-upgrade-controller/blob/v0.20.2/pkg/upgrade/job/job.go#L184-L470); design constraints in [README L26-L40](https://github.com/rancher/system-upgrade-controller/blob/v0.20.2/README.md#L26-L40)).
The Job is a Kubernetes object that runs to completion whether or not the controller pod is alive.
Its retry budget is the Job `backoffLimit`, 99 in the shipped config, with a 900s active deadline ([manifest L23-L24](https://github.com/rancher/system-upgrade-controller/blob/v0.20.2/manifests/system-upgrade-controller.yaml#L23-L24)).

The controller pod is excluded from drains: drains always add `upgrade.cattle.io/controller DoesNotExist` to the pod selector ([job.go L351-L353](https://github.com/rancher/system-upgrade-controller/blob/v0.20.2/pkg/upgrade/job/job.go#L351-L353)), and the controller pod carries that label "necessary to avoid drain" ([manifest L49](https://github.com/rancher/system-upgrade-controller/blob/v0.20.2/manifests/system-upgrade-controller.yaml#L49)).
SUC deliberately keeps itself on the node being upgraded and makes itself disposable, the opposite of evacuating.

The payload is written to survive the disruption it causes.
k3s-upgrade's `upgrade` is `get_k3s_process_info; replace_binary; kill_k3s_process` ([upgrade.sh L230-L234](https://github.com/k3s-io/k3s-upgrade/blob/9cf272d6186367ad80b61b343f74ab807b04fc01/scripts/upgrade.sh#L230-L234)), and `replace_binary` exits 0 with "Binary already been replaced" when the new binary is already in place ([L62-L82](https://github.com/k3s-io/k3s-upgrade/blob/9cf272d6186367ad80b61b343f74ab807b04fc01/scripts/upgrade.sh#L62-L82)).
A pod killed by the k3s restart it triggered is retried by the Job and then succeeds trivially.
The README warns that upgrades must be idempotent: "there be dragons" ([README L40](https://github.com/rancher/system-upgrade-controller/blob/v0.20.2/README.md#L40)).

### Rollout progress across restarts

- The cursor is `Plan.status.applying`, the node names currently being upgraded.
  `SelectConcurrentNodes` first keeps the nodes already in `applying`, then fills up to `spec.concurrency` with nodes whose `plan.upgrade.cattle.io/<plan>` label is not the plan's `latestHash`.
  New candidates come in a deterministic hash order, so repeated syncs do not create extra Jobs ([plan.go L155-L212](https://github.com/rancher/system-upgrade-controller/blob/v0.20.2/pkg/upgrade/plan/plan.go#L155-L212)).
  The handler writes `applying` back to status ([handle_upgrade.go L129-L185](https://github.com/rancher/system-upgrade-controller/blob/v0.20.2/pkg/upgrade/handle_upgrade.go#L129-L185)).
- Completion is recorded on the node: when a Job completes, the controller sets the node's plan label to the plan hash (after an optional `postCompleteDelay`) ([handle_batch.go L114-L140](https://github.com/rancher/system-upgrade-controller/blob/v0.20.2/pkg/upgrade/handle_batch.go#L114-L140)).
  The node label is the durable "this node is done at this spec" fact.
- A Job running for a node not in `applying` is "running out-of-turn" and is deleted ([handle_batch.go L145-L149](https://github.com/rancher/system-upgrade-controller/blob/v0.20.2/pkg/upgrade/handle_batch.go#L145-L149)).
  So is a Job for a superseded plan version ([L62-L66](https://github.com/rancher/system-upgrade-controller/blob/v0.20.2/pkg/upgrade/handle_batch.go#L62-L66)).

### Cordon and drain ordering

Cordon and drain are init containers in the upgrade Job's pod, which run `kubectl cordon` or `kubectl drain`.
They run after the optional `prepare` init container and before the `upgrade` container ([job.go L320-L426](https://github.com/rancher/system-upgrade-controller/blob/v0.20.2/pkg/upgrade/job/job.go#L320-L426); README "The prepare init container ... is run before cordon/drain which is run before the upgrade container", [README L122](https://github.com/rancher/system-upgrade-controller/blob/v0.20.2/README.md#L122)).
Uncordon is done by the controller when it observes the Job complete, even before `postCompleteDelay` has elapsed ([handle_batch.go L134-L138](https://github.com/rancher/system-upgrade-controller/blob/v0.20.2/pkg/upgrade/handle_batch.go#L134-L138)).
A failed Job leaves the node cordoned and sets `Complete` false with reason `JobFailed` ([L84-L101](https://github.com/rancher/system-upgrade-controller/blob/v0.20.2/pkg/upgrade/handle_batch.go#L84-L101)).

### etcd quorum

SUC has no etcd awareness.
The k3s example gets ordering from configuration: the server plan uses `concurrency: 1` and `cordon: true` (no drain), and the agent plan's `prepare` step runs `prepare k3s-server` ([examples/k3s-upgrade.yaml](https://github.com/rancher/system-upgrade-controller/blob/v0.20.2/examples/k3s-upgrade.yaml)).
That step blocks until the server plan's `status.applying` is empty and every control-plane node's kubelet reports the target version ([upgrade.sh L130-L172](https://github.com/k3s-io/k3s-upgrade/blob/9cf272d6186367ad80b61b343f74ab807b04fc01/scripts/upgrade.sh#L130-L172)).
There is no post-gate: the k3s Job completes as soon as it has signalled k3s, so the next server can start before the previous one's etcd member has rejoined.
`postCompleteDelay` is the only knob ([types.go L85](https://github.com/rancher/system-upgrade-controller/blob/v0.20.2/pkg/apis/upgrade.cattle.io/v1/types.go#L85)).

### Status and conditions

`Plan.status` holds conditions `LatestResolved`, `Validated` and `Complete`, plus `latestVersion`, `latestHash` and `applying` ([types.go L19-L23, L94-L110](https://github.com/rancher/system-upgrade-controller/blob/v0.20.2/pkg/apis/upgrade.cattle.io/v1/types.go#L19-L110)).
`Complete` carries `Waiting` when outside `spec.window` ([handle_upgrade.go L158-L166](https://github.com/rancher/system-upgrade-controller/blob/v0.20.2/pkg/upgrade/handle_upgrade.go#L158-L166)).
Events include `SyncJob`, `JobComplete`, `JobCompleteWaiting` and `JobFailed`.
Per-node truth is the plan-hash label.

## kured

### No controller, no leader

kured is a DaemonSet that tolerates the control-plane taint ([kured-ds.yaml L15-L35](https://github.com/kubereboot/kured/blob/1.23.0/kured-ds.yaml#L15-L35)), so every node runs an agent that reboots its own host.
There is no leader election.
Mutual exclusion is a lock in the `weave.works/kured-node-lock` annotation on the kured DaemonSet object ([main.go L100-L105](https://github.com/kubereboot/kured/blob/1.23.0/cmd/kured/main.go#L100-L105)).
The lock is acquired by a read-modify-`Update` that retries on a conflict, so the apiserver's resourceVersion check is the arbiter ([daemonsetlock.go L139-L187](https://github.com/kubereboot/kured/blob/1.23.0/pkg/daemonsetlock/daemonsetlock.go#L139-L187)).
`--concurrency` (default 1) switches to a multi-holder lock ([main.go L168](https://github.com/kubereboot/kured/blob/1.23.0/cmd/kured/main.go#L168)).

### Progress across the restart it causes

The reboot kills the agent by design, so the lock is the persisted state.
The lock value records `NodeID`, `Created`, `TTL` and `Metadata.Unschedulable`, the node's schedulability before kured cordoned it ([daemonsetlock.go L73-L82](https://github.com/kubereboot/kured/blob/1.23.0/pkg/daemonsetlock/daemonsetlock.go#L73-L82)).
On startup the agent first checks whether it holds the lock.
If it does, it knows a prior run tried to reboot, so it uncordons unless the node was already unschedulable before.
It clears its `reboot-in-progress` annotation once the sentinel no longer demands a reboot, then releases the lock, optionally after `--lock-release-delay` ([main.go L567-L617](https://github.com/kubereboot/kured/blob/1.23.0/cmd/kured/main.go#L567-L617); [daemonsetlock.go L213-L252](https://github.com/kubereboot/kured/blob/1.23.0/pkg/daemonsetlock/daemonsetlock.go#L213-L252)).
The lock TTL defaults to 0, so a node that never comes back holds the lock forever ([main.go L148-L149](https://github.com/kubereboot/kured/blob/1.23.0/cmd/kured/main.go#L148-L149)).
That is deliberately fail-closed.

### Cordon and drain ordering

The order is: check that a reboot is required and allowed in the time window, check blockers, acquire the lock, then cordon and drain.
A failed drain releases the lock and uncordons, unless `--force-reboot` is set.
Then comes the optional `rebootDelay`, then the reboot, then an endless wait ([main.go L640-L726](https://github.com/kubereboot/kured/blob/1.23.0/cmd/kured/main.go#L640-L726)).
The drain uses kubectl's drain library with `IgnoreAllDaemonSets: true`, so the agent never evicts itself ([main.go L418-L460](https://github.com/kubereboot/kured/blob/1.23.0/cmd/kured/main.go#L418-L460)).

### etcd quorum

kured has no etcd or control-plane awareness.
The closest controls are blockers checked before taking the lock: firing Prometheus alerts (`--prometheus-url`, `--alert-filter-regexp`) and the presence of pods matching `--blocking-pod-selector` ([main.go L152-L155, L186-L187, L268-L274](https://github.com/kubereboot/kured/blob/1.23.0/cmd/kured/main.go#L152-L274)).
With `concurrency: 1` and a lock that is only released after the node is back, at most one node is down at a time.
"Back" means only that the agent restarted and could reach the apiserver; kured checks no etcd member health.

### Status

kured has no CRD.
It records the lock annotation, optional node annotations `weave.works/kured-reboot-in-progress` and `weave.works/kured-most-recent-reboot-needed` (`--annotate-nodes`, [main.go L196-L197, L646-L662](https://github.com/kubereboot/kured/blob/1.23.0/cmd/kured/main.go#L196-L662)), and the `kured_reboot_required{node}` gauge ([main.go L91-L96](https://github.com/kubereboot/kured/blob/1.23.0/cmd/kured/main.go#L91-L96)).

## How cairn's case differs

The operator's deploy step is unlike all three:

- **It is a long-lived process in the operator pod, not an object.**
  KCP's unit of work is a Machine deletion or an annotation an extension acts on, SUC's is a Job, and kured's is a reboot that kills the agent.
  `clan machines update` is an SSH session from the operator pod.
  If the pod dies, the session dies.
  Clan wraps activation in `systemd-run` so the switch itself survives an SSH drop ([UPGRADES.md, Summary of Decisions](../UPGRADES.md)), but the operator loses the exit status and the build output.
- **The apiserver the operator depends on may be the one restarting.**
  A control-plane machine is drained only when `schedulable` (see the [phase 2 orchestrator](../UPGRADES.md#phase-2-the-orchestrator)), so the operator pod can sit on the machine whose etcd and apiserver restart.
  Its Lease renewals then fail. If they fail past the renew deadline, the process exits, as both controller-runtime and wrangler do.
  The design has to assume leadership can be lost mid-step.
- **The phase 2 loop keeps its cursor in memory.**
  [`rollout.run`](../../pkg/upgrade/rollout.go) iterates `selected`, and resuming means `--from <machine>`.
  None of the prior art works that way.

## Patterns that fit cairn-operator

1. **Derive progress from durable facts, as all three do, and keep a cursor only as a hint.**
   Put the per-machine target in `ClusterUpgrade.spec`: the plan JSON, plus each machine's desired system toplevel store path, which the plan can emit from the same evaluation.
   On every reconcile, treat a machine as done when its running system (`/run/current-system` over SSH, or a node annotation a NixOS unit writes at activation) equals the desired path and its post-gate passes.
   This is SUC's node-hash label and KCP's `UpToDate` comparison.
   A status cursor (`status.machines[].phase`) is then reporting, not truth.
2. **Write intent before acting, and make the step re-runnable.**
   Before invoking clan, set `status.current = {machine, desiredPath, startedAt}` (or a machine-level annotation), like KCP's `UpdateInProgressAnnotation`.
   A restarted leader that finds `current` set does not pick a new machine.
   It re-runs `clan machines update` for that machine, which is a no-op build and switch if the earlier run finished, much as k3s-upgrade's `replace_binary` exits early, then re-runs the post-gate.
   Set the pre-terminate-style rule that only one machine may be in `current` at a time.
3. **Run the deploy as a Job, not in the reconciler.**
   This is SUC's split, adapted to clan's push model.
   The reconciler creates a Job (`backoffLimit`, `activeDeadlineSeconds`) that runs `clan machines update <machine>` and exits.
   Required node anti-affinity keeps the Job off the target machine, and the reconciler watches the Job's conditions.
   The SSH session then survives a controller restart or leadership change, and its result lands on an object rather than in a dead process's memory.
   The Job's pod spec is also the natural place to mount the `command=`-restricted SSH key from the phase 4 credential discussion, scoped to that one Job.
4. **Evacuate the operator from the target only when that is cheap, and otherwise accept losing it.**
   KCP gets this for free because its machines are drained.
   For non-drained control-plane machines, either add required node anti-affinity against `status.current`, which forces a reschedule before the deploy Job starts, or follow SUC: let the controller stay, make it disposable, and rely on (1) through (3).
   Either way, with `requireExplicitUpdate` and serial machines, a lost leader cannot cause two machines to update at once, provided (2) holds.
   Correct the phase 4 wording in `UPGRADES.md`: leader election ensures a single actor, and drain or affinity is what moves the pod.
5. **Keep the pre-gate as KCP-style preflight, and add leadership forwarding.**
   cairn's pre-gate already matches KCP's preflight with `excludeFor`: other members healthy, target excluded.
   Two KCP additions fit directly.
   First, refuse to start while any machine is mid-step (KCP's `HasDeletingMachine`, i.e. `status.current` set and not post-gated).
   Second, move etcd leadership off the target member before its update (`etcdctl move-leader`, as in `forwardEtcdLeadership`), so the restart does not force an election.
   KCP's fault-tolerance math (`targetEtcdClusterHealthy`) is a possible relaxation for 5-member clusters, but the current "every other member healthy" rule is stricter and simpler, so keep it unless it blocks real rollouts.
6. **Persist drain and gate timestamps in status.**
   Like `status.deletion.nodeDrainStartTime`, store `drainStartedAt` and `postGateStartedAt` so `--timeout` semantics survive a restart instead of resetting.
   Like SUC, uncordon only after the post-gate passes, and leave the machine cordoned on failure (phase 2 already does both).
7. **Conditions, modelled on KCP rather than SUC.**
   A top-level `Ready`/`Available` plus `RollingOut` (with `upToDateMachines`/`machines` counts, like `upToDateReplicas`), `EtcdClusterHealthy` and `ControlPlaneComponentsHealthy`.
   Add a `Blocked` or `Progressing=False` reason that names the failing gate, as KCP puts preflight results in condition messages, plus `observedGeneration`.
   Use Events (`MachineUpdating`, `PostGatePassed`, `GateFailed`, `LeadershipForwarded`) for the history.
8. **Do not borrow kured's node-local lock.**
   kured shows the fail-closed lock (TTL 0, stored with the pre-cordon schedulability) works for one reboot per node.
   `UPGRADES.md` already rejects node-local coordination for etcd.
   The one idea worth keeping is recording `wasUnschedulable` before cordoning, so an operator-cordoned machine is not uncordoned if a human had cordoned it first.
   `rollout.go` currently uncordons unconditionally after a drained update.
