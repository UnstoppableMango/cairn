# The order an upgrade walks one evaluated `cairn.clusters.<name>`, emitted as
# the `cairn-upgrade-plan.<name>` flake output and read by `cairn-upgrade`
# (pkgs/upgrade). It comes from the same evaluation the machines are built
# from, so a machine added to the cluster is in the rollout without a list to
# keep in sync.
#
# Control-plane machines go first, then workers, which keeps every kubelet at
# or behind its apiserver for the whole rollout. Within the control plane the
# lowest keepalived priority goes first and the default VIP holder last, so
# the VIP moves at most once.
{ lib }:
{
  cluster,
  # Machine name to the `clan.core.networking.targetHost` its NixOS config
  # declares, or null. Only `--rollback` connects to a machine directly;
  # everything else goes through clan or the cluster's own endpoints.
  targetHostOf ? _: null,
}:
let
  svc = cluster.services;

  runs = service: m: svc.${service}.enable && lib.elem m svc.${service}.machines;

  # Same precedence as `effectiveVersion` in ./lower.nix.
  versionOf =
    m:
    if cluster.machines.${m}.kubernetesVersion != null then
      cluster.machines.${m}.kubernetesVersion
    else
      cluster.versions.kubernetes;

  entry =
    m:
    let
      mc = cluster.machines.${m};
      targetHost = targetHostOf m;
    in
    {
      machine = m;
      inherit (mc) role ip;
      targetHost = if targetHost != null then targetHost else "root@${mc.ip}";
      etcd = runs "etcd" m;
      apiserver = runs "apiserver" m;
      kubelet = runs "kubelet" m;
      # A master-only machine is tainted unschedulable, so it holds no pods
      # worth draining.
      drain = runs "kubelet" m && (mc.role == "worker" || mc.schedulable);
      # The minor the node's kubelet should report once updated, or null when
      # the cluster follows nixpkgs and the version is unknowable here.
      kubernetesVersion = versionOf m;
    };

  names = lib.attrNames cluster.machines;

  isControlPlane = m: runs "etcd" m || runs "apiserver" m;

  # An unset priority falls back to the loadbalancer service's own default
  # (modules/service/loadbalancer/options.nix).
  priority =
    m:
    if cluster.machines.${m}.keepalivedPriority != null then
      cluster.machines.${m}.keepalivedPriority
    else
      100;

  # `sort` is not stable, so the name breaks ties explicitly.
  controlPlane = lib.sort (
    a: b: if priority a != priority b then priority a < priority b else a < b
  ) (lib.filter isControlPlane names);

  workers = lib.filter (m: !isControlPlane m) names;
in
{
  inherit (cluster) clusterName;
  apiserverPort = svc.apiserver.port;
  machines = map entry (controlPlane ++ workers);
}
