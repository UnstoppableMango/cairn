# Two rules shape this file.
# Settings never hang off tags: clan reads only `roles.<role>.settings` and `roles.<role>.machines.<n>.settings` and silently ignores anything under `tags`, so every assignment is per machine.
# `cluster.cairn.*` options exist only on machines whose role imports modules/service/cluster.nix, so each cluster-wide value is scoped to the services that declare it (`clusterScoped`).
{ lib, cairnLib }:
{
  # `multi` turns on instance-name prefixing.
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

  # Caught here because clan reports a missing machine as a role-assignment failure several layers from the typo.

  checkMachines =
    where: machines:
    let
      unknown = filter (m: !(cluster.machines ? ${m})) machines;
    in
    throwIf (unknown != [ ])
      "${loc}.services.${where}: no such machine ${concatStringsSep ", " unknown}. Machines must be declared in ${loc}.machines."
      machines;

  controlPlane = lib.attrNames (lib.filterAttrs (_: m: m.role == "control-plane") cluster.machines);

  # null follows nixpkgs, whose version is unknowable here.
  effectiveVersion =
    m:
    if cluster.machines.${m}.kubernetesVersion != null then
      cluster.machines.${m}.kubernetesVersion
    else
      cluster.versions.kubernetes;

  # kubelet may not set `node-role.kubernetes.io/*` on itself.
  # Merged under the machine's own `nodeLabels`, so an entry there wins.
  roleLabel = m: { "node-role.kubernetes.io/${m.role}" = ""; };

  effectiveMaxPods =
    m:
    if cluster.machines.${m}.maxPods != null then
      cluster.machines.${m}.maxPods
    else
      svc.kubelet.maxPods;

  # Per machine, since a node carrying a storage daemon or build agent holds back memory an identical node does not.
  effectiveReservation =
    key: m:
    if cluster.machines.${m}.${key} != null then cluster.machines.${m}.${key} else svc.kubelet.${key};

  # Per machine, so nodes can move over one at a time.
  effectiveNixSnapshotter =
    m:
    if cluster.machines.${m}.nixSnapshotter != null then
      cluster.machines.${m}.nixSnapshotter
    else
      svc.kubelet.nixSnapshotter;

  minorOf = v: lib.toInt (lib.elemAt (lib.splitString "." v) 1);

  anyMachinePin = lib.any (m: m.kubernetesVersion != null) (lib.attrValues cluster.machines);

  # A kubelet may run up to three minors behind the apiserver, never ahead.
  # Checkable only between explicit pins.
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

  mkModule = service: {
    name = "@UnstoppableMango/${service}";
    input = cluster.moduleInput;
  };

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

  # `types.str` merges definitions that agree, so a disagreement between services is an eval error.
  clusterSettings = {
    inherit (cluster) vip clusterName;
  };

  instances =
    listToAttrs (
      filter (x: x != null) [
        (instance (svc.pki.enable && svc.pki.machines != [ ]) "${prefix}pki" {
          module = mkModule "pki";
          roles.node = mkRole svc.pki "pki" svc.pki.machines (_: {
            inherit (svc.pki) generatorPrefix certValidityDays caChain;
          });
        })

        (instance (svc.etcd.enable && svc.etcd.machines != [ ]) "${prefix}etcd" {
          module = mkModule "etcd";
          roles.member = mkRole svc.etcd "etcd" svc.etcd.machines (
            m:
            {
              ip = machineIp m;
              inherit (cluster) clusterName;
            }
            // optionalAttrs (effectiveVersion m != null) {
              kubernetesVersion = effectiveVersion m;
            }
          );
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

        (instance (svc.kubelet.enable && svc.kubelet.machines != [ ]) "${prefix}kubelet" {
          module = mkModule "kubelet";
          roles.node = mkRole svc.kubelet "kubelet" svc.kubelet.machines (
            m:
            {
              ip = machineIp m;
              # nixpkgs taints a master-only machine unschedulable, so a
              # control-plane machine is a node only when asked to be.
              schedulable = cluster.machines.${m}.role == "worker" || cluster.machines.${m}.schedulable;
              maxPods = effectiveMaxPods m;
              systemReserved = effectiveReservation "systemReserved" m;
              kubeReserved = effectiveReservation "kubeReserved" m;
              evictionHard = effectiveReservation "evictionHard" m;
              nixSnapshotter = effectiveNixSnapshotter m;
            }
            // clusterSettings
            // optionalAttrs (effectiveVersion m != null) {
              kubernetesVersion = effectiveVersion m;
            }
          );
        })

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
          roles.node = mkRole svc.kubeconfig "kubeconfig" svc.kubeconfig.machines (
            m:
            clusterSettings
            // optionalAttrs (effectiveVersion m != null) {
              kubernetesVersion = effectiveVersion m;
            }
          );
        })

        (instance (svc.inoculant.enable && svc.inoculant.machines != [ ]) "${prefix}inoculant" {
          module = mkModule "inoculant";
          roles.node = mkRole svc.inoculant "inoculant" svc.inoculant.machines (m: {
            nodeLabels = roleLabel cluster.machines.${m} // cluster.machines.${m}.nodeLabels;
          });
        })

        (instance (svc.coredns.enable && svc.coredns.machines != [ ]) "${prefix}coredns" {
          module = mkModule "coredns";
          roles.control-plane = mkRole svc.coredns "coredns" svc.coredns.machines (
            m: optionalAttrs (effectiveVersion m != null) { kubernetesVersion = effectiveVersion m; }
          );
        })

        (instance (svc.metrics-server.enable && svc.metrics-server.machines != [ ])
          "${prefix}metrics-server"
          {
            module = mkModule "metrics-server";
            roles.control-plane = mkRole svc.metrics-server "metrics-server" svc.metrics-server.machines (
              m: optionalAttrs (effectiveVersion m != null) { kubernetesVersion = effectiveVersion m; }
            );
          }
        )

        (instance (svc.flux.enable && svc.flux.machines != [ ]) "${prefix}flux" {
          module = mkModule "flux";
          roles.control-plane = mkRole svc.flux "flux" svc.flux.machines (_: {
            inherit (svc.flux) url branch path;
          });
        })
      ]
    )
    // cluster.extraInstances;

  assigned = enable: machines: if enable then machines else [ ];

  pkiMachines = assigned svc.pki.enable svc.pki.machines;
  etcdMachines = assigned svc.etcd.enable svc.etcd.machines;
  corednsMachines = assigned svc.coredns.enable svc.coredns.machines;
  metricsServerMachines = assigned svc.metrics-server.enable svc.metrics-server.machines;

  kubeletMachines = assigned svc.kubelet.enable svc.kubelet.machines;

  # pki/node.nix and etcd/member.nix deliberately do not import modules/service/cluster.nix.
  clusterScoped =
    assigned svc.apiserver.enable svc.apiserver.machines
    ++ kubeletMachines
    ++ assigned svc.loadbalancer.enable svc.loadbalancer.machines
    ++ assigned svc.network.enable svc.network.machines
    ++ assigned svc.kubeconfig.enable svc.kubeconfig.machines;

  corednsConfig = {
    inherit (svc.coredns) clusterDomain replicas;
  }
  // optionalAttrs (svc.coredns.nodeNames != null) { inherit (svc.coredns) nodeNames; }
  // optionalAttrs (svc.coredns.serviceClusterIpRange != null) {
    inherit (svc.coredns) serviceClusterIpRange;
  }
  // optionalAttrs (svc.coredns.clusterIp != null) { inherit (svc.coredns) clusterIp; }
  // optionalAttrs (svc.coredns.corefile != null) { inherit (svc.coredns) corefile; }
  // optionalAttrs (svc.coredns.package != null) { inherit (svc.coredns) package; }
  // optionalAttrs (svc.coredns.image != null) { inherit (svc.coredns) image; };

  metricsServerConfig = {
    inherit (svc.metrics-server) replicas metricResolution extraArgs;
  }
  // optionalAttrs (svc.metrics-server.nodeNames != null) {
    inherit (svc.metrics-server) nodeNames;
  }
  // optionalAttrs (svc.metrics-server.package != null) { inherit (svc.metrics-server) package; }
  // optionalAttrs (svc.metrics-server.image != null) { inherit (svc.metrics-server) image; };

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
        cluster.cairn.etcd = {
          inherit (svc.etcd) initialClusterState autoJoin removedMembers;
        };
      }
      ++ optional (cluster.versions.kubernetesPackage != null && elem mname kubeletMachines) {
        services.kubernetes.package = cluster.versions.kubernetesPackage;
      }
      ++ optional (cluster.versions.etcdPackage != null && elem mname etcdMachines) {
        cluster.cairn.etcd.package = cluster.versions.etcdPackage;
      }
      ++ optional (elem mname corednsMachines) {
        cluster.cairn.coredns = corednsConfig;
      }
      ++ optional (elem mname metricsServerMachines) {
        cluster.cairn.metricsServer = metricsServerConfig;
      }
      ++ optional (elem mname kubeletMachines) {
        cluster.cairn.kubelet = {
          inherit (svc.kubelet) rootDir containerdRuntimes;
        };
      }
      ++ optional (svc.node-exporter.openFirewall && elem mname kubeletMachines) {
        networking.firewall.allowedTCPPorts = [ svc.node-exporter.port ];
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
