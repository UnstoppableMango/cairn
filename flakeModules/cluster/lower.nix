# Lowers one evaluated `cairn.clusters.<name>` (see ./options.nix) into a clan
# module: the inventory instances that assign cairn's services to machines,
# plus the NixOS configuration those machines need.
#
# Two rules shape everything below.
#
# 1. Settings never hang off tags. clan only reads `roles.<role>.settings` and
#    `roles.<role>.machines.<n>.settings`; anything nested under `tags` is
#    silently ignored. So every assignment here is explicit and per-machine,
#    built with `cairnLib.inventory.mkMachines`. Tags are membership-only, and
#    only for the consumer's own use.
#
# 2. `cluster.cairn.*` options only exist on a machine whose role module
#    imports modules/service/cluster.nix. Emitting a cluster-wide NixOS value
#    onto a machine without one is an "option does not exist" error, so each
#    is scoped to the services that declare it (see `clusterScoped` below).
{ lib, cairnLib }:
{
  # Attribute name of the cluster, and whether the flake declares more than
  # one (which turns on instance-name prefixing).
  name,
  multi,
}:
cluster:
let
  inherit (lib)
    concatStringsSep
    elem
    filter
    genAttrs
    listToAttrs
    nameValuePair
    optional
    optionalAttrs
    optionalString
    throwIf
    ;

  svc = cluster.services;

  prefix =
    if cluster.instancePrefix != null then cluster.instancePrefix else optionalString multi "${name}-";

  loc = "cairn.clusters.${name}";

  # ─── Validation ──────────────────────────────────────────────────────────
  # Caught here rather than left to clan's module resolution, which reports a
  # missing machine as a role-assignment failure several layers removed from
  # the typo that caused it.

  checkMachines =
    where: machines:
    let
      unknown = filter (m: !(cluster.machines ? ${m})) machines;
    in
    throwIf (unknown != [ ])
      "${loc}.services.${where}: no such machine ${concatStringsSep ", " unknown}. Machines must be declared in ${loc}.machines."
      machines;

  controlPlane = lib.attrNames (lib.filterAttrs (_: m: m.role == "control-plane") cluster.machines);

  # kubepkgs minor a machine runs: its own pin, else the cluster's, else null
  # (follow nixpkgs, whose version is unknowable here).
  effectiveVersion =
    m:
    if cluster.machines.${m}.kubernetesVersion != null then
      cluster.machines.${m}.kubernetesVersion
    else
      cluster.versions.kubernetes;

  minorOf = v: lib.toInt (lib.elemAt (lib.splitString "." v) 1);

  anyMachinePin = lib.any (m: m.kubernetesVersion != null) (lib.attrValues cluster.machines);

  # Kubernetes' skew policy: a kubelet may run up to three minors behind the
  # apiserver, never ahead. Only checkable between explicit pins; the
  # apiserver side is the oldest pinned control-plane machine.
  cpMinors = map minorOf (lib.filter (v: v != null) (map effectiveVersion controlPlane));
  minCpMinor = lib.foldl' lib.min (lib.head cpMinors) cpMinors;
  skewViolations = lib.filter (
    m:
    let
      v = effectiveVersion m;
    in
    cluster.machines.${m}.role == "worker"
    && v != null
    && cpMinors != [ ]
    && (minorOf v > minCpMinor || minorOf v < minCpMinor - 3)
  ) (lib.attrNames cluster.machines);

  validate =
    x:
    throwIf (controlPlane == [ ])
      "${loc}: no machine has `role = \"control-plane\"`; a cluster needs at least one."
      (
        throwIf (svc.loadbalancer.enable && svc.loadbalancer.interface == null)
          "${loc}.services.loadbalancer.interface must be set when the loadbalancer is enabled; keepalived needs an interface to run VRRP on."
          (
            throwIf (svc.flux.enable && svc.flux.url == null)
              "${loc}.services.flux.url must be set when flux is enabled; there is nothing to sync from otherwise."
              (
                throwIf
                  (
                    cluster.versions.kubernetesPackage != null && (cluster.versions.kubernetes != null || anyMachinePin)
                  )
                  "${loc}.versions.kubernetesPackage is mutually exclusive with `versions.kubernetes` and per-machine `kubernetesVersion` pins."
                  (
                    throwIf (skewViolations != [ ])
                      "${loc}: worker machine(s) ${concatStringsSep ", " skewViolations} violate the Kubernetes version skew policy: a kubelet may run up to three minors behind the oldest pinned control-plane machine (1.${toString minCpMinor}), never ahead. See docs/UPGRADES.md."
                      x
                  )
              )
          )
      );

  # ─── Inventory ───────────────────────────────────────────────────────────

  mkModule = service: {
    name = "@UnstoppableMango/${service}";
    input = cluster.moduleInput;
  };

  # `settingsFn` gets the machine name and returns that machine's settings;
  # the service's own `settings` escape hatch is merged over the top so it
  # always wins.
  mkRole = cfg: service: machines: settingsFn: {
    machines = cairnLib.inventory.mkMachines { } (
      genAttrs (checkMachines service machines) (m: settingsFn m // cfg.settings)
    );
    extraModules = cfg.extraModules;
  };

  instance =
    enable: iname: value:
    if enable then nameValuePair iname value else null;

  machineIp = m: cluster.machines.${m}.ip;

  # Cluster-wide settings several services all forward. `types.str` merges
  # definitions that agree, so the repetition is deliberate and a disagreement
  # would be an eval error.
  clusterSettings = {
    inherit (cluster) vip clusterName;
  };

  instances =
    listToAttrs (
      filter (x: x != null) [
        (instance (svc.pki.enable && svc.pki.machines != [ ]) "${prefix}pki" {
          module = mkModule "pki";
          roles.node = mkRole svc.pki "pki" svc.pki.machines (_: {
            inherit (svc.pki) generatorPrefix certValidityDays;
          });
        })

        (instance (svc.etcd.enable && svc.etcd.machines != [ ]) "${prefix}etcd" {
          module = mkModule "etcd";
          roles.member = mkRole svc.etcd "etcd" svc.etcd.machines (m: {
            ip = machineIp m;
            inherit (cluster) clusterName;
          });
        })

        (instance (svc.apiserver.enable && svc.apiserver.machines != [ ]) "${prefix}apiserver" {
          module = mkModule "apiserver";
          roles.control-plane = mkRole svc.apiserver "apiserver" svc.apiserver.machines (
            m:
            {
              ip = machineIp m;
              apiserverPort = svc.apiserver.port;
              inherit (svc.apiserver) allowPrivileged serviceClusterIP;
            }
            // clusterSettings
          );
        })

        (instance
          (
            svc.kubelet.enable && (svc.kubelet.controlPlaneMachines != [ ] || svc.kubelet.workerMachines != [ ])
          )
          "${prefix}kubelet"
          {
            module = mkModule "kubelet";
            roles =
              optionalAttrs (svc.kubelet.controlPlaneMachines != [ ]) {
                # Rides alongside the apiserver, which already forwards the
                # cluster-wide settings; only the node's own IP is needed here.
                control-plane = mkRole svc.kubelet "kubelet" svc.kubelet.controlPlaneMachines (
                  m:
                  {
                    ip = machineIp m;
                  }
                  // optionalAttrs (effectiveVersion m != null) {
                    kubernetesVersion = effectiveVersion m;
                  }
                );
              }
              // optionalAttrs (svc.kubelet.workerMachines != [ ]) {
                worker = mkRole svc.kubelet "kubelet" svc.kubelet.workerMachines (
                  m:
                  {
                    ip = machineIp m;
                  }
                  // clusterSettings
                  // optionalAttrs (effectiveVersion m != null) {
                    kubernetesVersion = effectiveVersion m;
                  }
                );
              };
          }
        )

        (instance (svc.loadbalancer.enable && svc.loadbalancer.machines != [ ]) "${prefix}loadbalancer" {
          module = mkModule "loadbalancer";
          roles.control-plane = mkRole svc.loadbalancer "loadbalancer" svc.loadbalancer.machines (
            m:
            {
              inherit (cluster) vip;
              inherit (svc.loadbalancer) interface virtualRouterId healthCheck;
            }
            // optionalAttrs (cluster.machines.${m}.keepalivedPriority != null) {
              inherit (cluster.machines.${m}) keepalivedPriority;
            }
          );
        })

        (instance (svc.network.enable && svc.network.machines != [ ]) "${prefix}network" {
          module = mkModule "network";
          roles.node = mkRole svc.network "network" svc.network.machines (_: clusterSettings);
        })

        (instance (svc.kubeconfig.enable && svc.kubeconfig.machines != [ ]) "${prefix}kubeconfig" {
          module = mkModule "kubeconfig";
          roles.node = mkRole svc.kubeconfig "kubeconfig" svc.kubeconfig.machines (_: clusterSettings);
        })

        (instance (svc.inoculant.enable && svc.inoculant.machines != [ ]) "${prefix}inoculant" {
          module = mkModule "inoculant";
          roles.node = mkRole svc.inoculant "inoculant" svc.inoculant.machines (m: {
            inherit (cluster.machines.${m}) nodeLabels;
          });
        })

        (instance (svc.coredns.enable && svc.coredns.machines != [ ]) "${prefix}coredns" {
          module = mkModule "coredns";
          roles.control-plane = mkRole svc.coredns "coredns" svc.coredns.machines (_: { });
        })

        (instance (svc.flux.enable && svc.flux.machines != [ ]) "${prefix}flux" {
          module = mkModule "flux";
          roles.control-plane = mkRole svc.flux "flux" svc.flux.machines (_: {
            inherit (svc.flux) url branch path;
          });
        })
      ]
    )
    // cluster.extraInstances;

  # ─── NixOS ───────────────────────────────────────────────────────────────

  assigned = enable: machines: if enable then machines else [ ];

  pkiMachines = assigned svc.pki.enable svc.pki.machines;
  etcdMachines = assigned svc.etcd.enable svc.etcd.machines;
  corednsMachines = assigned svc.coredns.enable svc.coredns.machines;

  # kubelet/common.nix declares `cluster.cairn.kubelet.*`, and both roles
  # import it, so this covers control-plane and worker machines alike.
  kubeletMachines = lib.unique (
    assigned svc.kubelet.enable svc.kubelet.controlPlaneMachines
    ++ assigned svc.kubelet.enable svc.kubelet.workerMachines
  );

  # Machines whose role modules import modules/service/cluster.nix, and so
  # have `cluster.cairn.apiServerPort` declared. pki/node.nix and
  # kubelet/common.nix (the control-plane kubelet) deliberately don't, so
  # neither appears here.
  clusterScoped =
    assigned svc.apiserver.enable svc.apiserver.machines
    ++ etcdMachines
    ++ assigned svc.kubelet.enable svc.kubelet.workerMachines
    ++ assigned svc.loadbalancer.enable svc.loadbalancer.machines
    ++ assigned svc.network.enable svc.network.machines
    ++ assigned svc.kubeconfig.enable svc.kubeconfig.machines;

  corednsConfig = {
    inherit (svc.coredns) clusterDomain replicas;
  }
  // optionalAttrs (svc.coredns.clusterIp != null) { inherit (svc.coredns) clusterIp; }
  // optionalAttrs (svc.coredns.corefile != null) { inherit (svc.coredns) corefile; }
  // optionalAttrs (svc.coredns.image != null) { inherit (svc.coredns) image; };

  machineModule = mname: m: {
    imports = [
      cluster.nixos
      m.nixos
    ];

    config = lib.mkMerge (
      # A bulk `clan machines update` deploys every machine in parallel,
      # restarting every etcd member and apiserver at once.
      optional cluster.requireExplicitUpdate {
        clan.core.deployment.requireExplicitUpdate = true;
      }
      # nixpkgs' kubernetes module taints a master-only machine
      # unschedulable; a cluster with no separate workers needs its
      # control-plane machines to also be nodes.
      ++ optional (m.schedulable && m.role == "control-plane") {
        services.kubernetes.roles = [ "node" ];
      }
      ++ optional (elem mname clusterScoped) {
        cluster.cairn.apiServerPort = cluster.apiServerPort;
      }
      ++ optional (elem mname pkiMachines) {
        cluster.cairn.pki = {
          ca.override = svc.pki.ca.override;
          certs = svc.pki.certs;
        };
      }
      ++ optional (elem mname etcdMachines) {
        cluster.cairn.etcd.initialClusterState = svc.etcd.initialClusterState;
      }
      ++ optional (cluster.versions.kubernetesPackage != null && elem mname kubeletMachines) {
        services.kubernetes.package = cluster.versions.kubernetesPackage;
      }
      ++ optional (cluster.versions.etcdPackage != null && elem mname etcdMachines) {
        services.etcd.package = cluster.versions.etcdPackage;
      }
      ++ optional (elem mname corednsMachines) {
        cluster.cairn.coredns = corednsConfig;
      }
      ++ optional (elem mname kubeletMachines) {
        cluster.cairn.kubelet.rootDir = svc.kubelet.rootDir;
      }
    );
  };
in
validate {
  inventory.machines = lib.mapAttrs (_: m: {
    tags = [ m.role ] ++ m.tags;
  }) cluster.machines;

  inventory.instances = instances;

  machines = lib.mapAttrs machineModule cluster.machines;
}
