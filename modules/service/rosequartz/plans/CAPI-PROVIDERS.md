# CAPI Provider Decision: k0smotron (+ Tinkerbell backburner)

## Context

Rosequartz is the CAPI **management cluster** (pik8s4-6 control-plane, agreus worker).
The **workload cluster** it will manage has this hardware:

| Role | Nodes | BMC |
|------|-------|-----|
| Control-plane | pik8s1-3 (Pi 4B, aarch64) | None |
| Workers | zeus, gaea, castor, pollux, ... (x86_64) | zeus: IPMI; gaea: Redfish; others: unknown |
| Storage | zeus, gaea, apollo | Rook-Ceph on dedicated raw block devices |

## Decision: k0smotron

### What it is

k0smotron is a CAPI provider (CNCF project, Mirantis) with two modes:

- **Hosted CP**: k0s control-plane runs as pods inside the management cluster (rosequartz). Eliminates physical CP nodes.
- **Remote CP**: k0s control-plane installed on actual machines via SSH. Preserves Pi-as-CP architecture.
- **RemoteMachine**: CAPI infra provider that provisions any pre-existing Linux machine via SSH. Installs k0s worker agent.

For this cluster: **Remote CP** on pik8s1-3 + **RemoteMachine** workers for zeus/gaea/castor/pollux.

### Why k0smotron fits

**Pi 4B nodes have no BMC.** This eliminates Metal3 (requires BMC on all nodes) and makes Tinkerbell the only PXE-based alternative. k0smotron sidesteps the BMC problem entirely — it only needs SSH.

**pik8s1-3 already run NixOS via clan.** k0smotron SSHs into pre-existing machines and installs k0s. No re-imaging, no PXE infrastructure, no DHCP conflict with pfSense.

**Rook-Ceph disk safety.** k0smotron does not touch disk layout — it only installs the k0s agent binary and a systemd unit. Ceph OSD disks on zeus/gaea remain raw and untouched. This is cleaner than any PXE-based provider, where reprovisioning workflows must explicitly avoid OSD disks.

**No new infrastructure components.** No tink-server, no boots DHCP proxy, no metadata server, no Ironic, no MAAS PostgreSQL backend. Just cert-manager + CAPI core + k0smotron controllers running in rosequartz.

**Preserves NixOS on workload nodes.** k0smotron is OS-agnostic — nodes can continue to run NixOS managed by clan. k0smotron only manages the k0s process, not the OS.

### Tradeoffs accepted

- **k0s instead of vanilla kubernetes** on workload cluster. k0s is a conformant Kubernetes distribution with embedded etcd HA. Operationally similar to kubeadm-based clusters but different tooling (`k0sctl`, `k0s` CLI).
- **No automatic reprovision cycle.** Node replacement requires a human to boot the new machine with an OS before CAPI can pick it up. Tinkerbell handles this automatically.
- **No power-cycle automation** without additional tooling. IPMI/Redfish on zeus/gaea is unused by k0smotron itself (can be added later via Rufio if needed).

### Architecture

```
rosequartz (management cluster)
├── CAPI core controllers
├── k0smotron controllers
│   ├── k0smotron CP pods (if hosted mode chosen)
│   └── RemoteMachine controller (SSH → workload nodes)
├── cert-manager
├── MetalLB
└── Flux

workload cluster
├── Control-plane: pik8s1-3 (NixOS, k0s via SSH)
│   └── k0s etcd HA, 3-node
└── Workers: zeus, gaea, castor, pollux, ...
    ├── NixOS (clan-managed OS)
    ├── k0s worker agent (k0smotron-managed)
    └── zeus/gaea: Rook-Ceph OSD disks (untouched by k0smotron)
```

### Secrets needed

SSH keys for k0smotron to reach all workload nodes — store in SOPS under `sops/`.
k0smotron `RemoteMachine` spec references a `Secret` with `address`, `user`, `privateKey`.

### References

- https://docs.k0smotron.io/stable/cluster-api/
- https://docs.k0smotron.io/v1.1.2/capi-remote/
- https://k0smotron.io/

---

## Backburner: Tinkerbell (CAPT)

### What it is

Tinkerbell is a CNCF bare-metal provisioning engine. CAPT (Cluster API Provider Tinkerbell) is its CAPI infrastructure provider. Provisioning is driven by **Workflows** — sequences of actions executed on a rescue OS to write the target OS image to disk. BMC management is handled by **Rufio** (speaks IPMI and Redfish).

Components that run on the management cluster:

| Component | Purpose | Network requirement |
|-----------|---------|---------------------|
| `tink-server` | gRPC workflow engine | MetalLB LB IP |
| `boots` | DHCP proxy + iPXE server | `hostNetwork: true` on VLAN 20 node |
| `hegel` | Instance metadata server | MetalLB LB IP |
| `rufio` | BMC controller (IPMI/Redfish) | In-cluster only |
| `CAPT` | CAPI infra provider | In-cluster |

### Why it was not chosen now

Operational overhead without day-one benefit. The Pi nodes are already running NixOS and don't need reprovisioning. Adding tink-server, boots (DHCP proxy), hegel, and rufio to rosequartz is significant complexity when SSH provisioning via k0smotron achieves the same result with no new infrastructure.

The DHCP proxy (`boots`) must run with `hostNetwork: true` and coordinate with pfSense to avoid DHCP conflicts — adds operational surface area.

Tinkerbell also requires OS images to be baked and hosted. A NixOS workflow would need a custom image built and a Tinkerbell action to write it.

### When to revisit Tinkerbell

- **Hardware churn is frequent** (drive failures, board replacements). Tinkerbell automates the full reprovision cycle — power-cycle via Rufio, PXE boot into rescue, write OS image, reboot. k0smotron requires a human to boot the replacement machine first.
- **Adding machines that have no prior OS** (new bare-metal nodes, factory-fresh). k0smotron requires SSH to a working Linux install; Tinkerbell handles blank hardware.
- **Disk-layout changes** at scale. Tinkerbell workflows control full disk setup. k0smotron leaves disk management to NixOS/clan (which is fine, but less automated).

### Integration path if adopted later

Tinkerbell and k0smotron are not mutually exclusive. Tinkerbell handles OS lifecycle (provisioning, reprovisioning); k0smotron handles k8s lifecycle (joining/leaving cluster). Workflow:

1. Tinkerbell provisions bare-metal node → NixOS image written to disk
2. Node reboots into NixOS, SSH comes up
3. k0smotron `RemoteMachine` SSHs in, installs k0s agent
4. Node joins workload cluster

### Rufio for zeus/gaea BMC (independent of CAPT)

Rufio can be deployed standalone (without full Tinkerbell stack) to provide BMC management (IPMI for zeus, Redfish for gaea). Useful for power-cycling nodes during maintenance without adopting the full Tinkerbell provisioning pipeline. `BaseboardManagement` CRD + `BMCJob` CRD are the relevant Rufio primitives.

### References

- https://tinkerbell.org/docs/services/cluster-api-provider-tinkerbell/
- https://github.com/tinkerbell/cluster-api-provider-tinkerbell
- https://github.com/tinkerbell/rufio
