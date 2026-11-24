# Emitted from the same evaluation the machines are built from, so a new machine joins the rollout with no list to keep in sync.
# Control plane first keeps every kubelet at or behind its apiserver; the lowest keepalived priority goes first and the default VIP holder last, so the VIP moves at most once.
{ lib }:
{
  cluster,
  # Only `--rollback` connects to a machine directly.
  targetHostOf ? _: null,
}:
let
  svc = cluster.services;

  runs = service: m: svc.${service}.enable && lib.elem m svc.${service}.machines;

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
      drain = runs "kubelet" m && (mc.role == "worker" || mc.schedulable);
      # null when the cluster follows nixpkgs and the version is unknowable here.
      kubernetesVersion = versionOf m;
    };

  names = lib.attrNames cluster.machines;

  isControlPlane = m: runs "etcd" m || runs "apiserver" m;

  priority =
    m:
    if cluster.machines.${m}.keepalivedPriority != null then
      cluster.machines.${m}.keepalivedPriority
    else
      100;

  # `sort` is not stable, so the name breaks ties.
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
