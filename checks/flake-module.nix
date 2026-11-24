# Covers the `cairn.clusters` option tree and its lowering, which nothing else in CI touches: the VM test writes its inventory by hand, and `nix flake check` never descends into examples/ha-cluster.
# Evaluation-only, since what needs proving is that clan accepts the lowered inventory and the settings land where they should.
{
  cairnModules,
  clan-core,
  nixpkgs,
  kubepkgs,
  cairn-upgrade,
  pkgs,
  lib,
}:
let
  inherit (pkgs.stdenv.hostPlatform) system;

  # The release the example pins, so assertions can name the exact derivations.
  pinned = kubepkgs.legacyPackages.${system}.kubernetes."1.36";

  cairnLib = import ../lib { inherit lib; };

  # `evalModules` rather than `flake-parts.lib.mkFlake` keeps this to the two files under test.
  exampleSpec = import ../examples/ha-cluster/cluster.nix {
    inherit system;
    moduleInput = "cairn";
  };

  evalSpec =
    spec:
    (lib.evalModules {
      modules = [
        { options.cairn = import ../flakeModules/cluster/options.nix { inherit lib; }; }
        { cairn.clusters.example = spec; }
      ];
    }).config.cairn.clusters.example;

  lowerSpec =
    spec:
    import ../flakeModules/cluster/lower.nix { inherit lib cairnLib; } {
      name = "example";
      multi = false;
    } (evalSpec spec);

  plan = import ../flakeModules/cluster/plan.nix { inherit lib; } {
    cluster = evalSpec exampleSpec;
  };
  planFile = pkgs.writeText "cairn-upgrade-plan.json" (builtins.toJSON { example = plan; });

  lowered = lowerSpec exampleSpec;

  # The example sets no cluster-wide reservation, so it cannot tell a fallback to the cluster value from one to `{}`.
  withClusterReservation = lowerSpec (
    lib.recursiveUpdate exampleSpec {
      services.kubelet.systemReserved = {
        cpu = "500m";
        memory = "1Gi";
      };
    }
  );

  withNodeExporter = lowerSpec (
    lib.recursiveUpdate exampleSpec {
      services.node-exporter = {
        openFirewall = true;
        port = 9200;
      };
    }
  );

  # clan reads `config.self.inputs` to resolve `module.input = "cairn"`.
  mkConsumer =
    lowered:
    clan-core.lib.clan {
      self.inputs = {
        cairn.clan.modules = cairnModules;
        inherit nixpkgs;
      };

      directory = ./.;

      imports = [ lowered ];

      inventory.meta.name = "cairn-flake-module";
    };

  consumer = mkConsumer lowered;

  firewallPortsOf =
    c: machine: c.config.nixosConfigurations.${machine}.config.networking.firewall.allowedTCPPorts;

  inherit (lowered.inventory) instances;

  settingsOf =
    instance: role: machine:
    instances.${instance}.roles.${role}.machines.${machine}.settings;

  expectations = [
    {
      msg = "every service in the example lowers to an instance";
      cond =
        lib.attrNames instances == [
          "apiserver"
          "coredns"
          "etcd"
          "flux"
          "inoculant"
          "kubeconfig"
          "kubelet"
          "loadbalancer"
          "metrics-server"
          "network"
          "pki"
        ];
    }
    {
      msg = "a lone cluster's instances are unprefixed";
      cond = instances ? pki;
    }
    {
      msg = "control-plane machines get etcd, workers don't";
      cond =
        lib.attrNames instances.etcd.roles.member.machines == [
          "cp1"
          "cp2"
          "cp3"
        ];
    }
    {
      msg = "each etcd member advertises its own IP";
      cond = (settingsOf "etcd" "member" "cp2").ip == "10.10.0.12";
    }
    {
      msg = "the loadbalancer moves the apiservers off the VIP-facing port";
      cond = (settingsOf "apiserver" "control-plane" "cp1").apiserverPort == 6444;
    }
    {
      msg = "cluster-wide settings reach the apiserver role";
      cond =
        let
          s = settingsOf "apiserver" "control-plane" "cp1";
        in
        s.vip == "10.10.0.10" && s.clusterName == "example";
    }
    {
      msg = "every machine runs a kubelet, under one role";
      cond =
        lib.attrNames instances.kubelet.roles.node.machines == [
          "cp1"
          "cp2"
          "cp3"
          "worker1"
          "worker2"
        ];
    }
    {
      msg = "every kubelet carries the cluster-wide settings";
      cond =
        (settingsOf "kubelet" "node" "worker1").vip == "10.10.0.10"
        && (settingsOf "kubelet" "node" "cp1").vip == "10.10.0.10";
    }
    {
      msg = "schedulability follows the machine's role";
      cond =
        (settingsOf "kubelet" "node" "worker1").schedulable
        && !(settingsOf "kubelet" "node" "cp1").schedulable;
    }
    {
      msg = "a per-machine maxPods overrides the cluster default";
      cond =
        (settingsOf "kubelet" "node" "worker1").maxPods == 250
        && (settingsOf "kubelet" "node" "worker2").maxPods == 110
        && (settingsOf "kubelet" "node" "cp1").maxPods == 110;
    }
    {
      msg = "maxPods reaches the rendered kubelet configuration";
      cond =
        consumer.config.nixosConfigurations.worker1.config.services.kubernetes.kubelet.extraConfig.maxPods
        == 250;
    }
    {
      msg = "a per-machine reservation overrides the cluster default";
      cond =
        (settingsOf "kubelet" "node" "worker1").systemReserved == {
          cpu = "2";
          memory = "4Gi";
        }
        && (settingsOf "kubelet" "node" "worker2").systemReserved == { };
    }
    {
      msg = "a machine without its own reservation takes the cluster's";
      cond =
        let
          reservedOf =
            m:
            withClusterReservation.inventory.instances.kubelet.roles.node.machines.${m}.settings.systemReserved;
        in
        reservedOf "worker1" == {
          cpu = "2";
          memory = "4Gi";
        }
        &&
          reservedOf "worker2" == {
            cpu = "500m";
            memory = "1Gi";
          };
    }
    {
      msg = "reservations reach the rendered kubelet configuration";
      cond =
        let
          cfg = consumer.config.nixosConfigurations.worker1.config.services.kubernetes.kubelet.extraConfig;
        in
        cfg.systemReserved == {
          cpu = "2";
          memory = "4Gi";
        }
        && cfg.evictionHard == { "memory.available" = "1Gi"; };
    }
    {
      # Left out rather than `{}`, so a consumer setting one directly on services.kubernetes.kubelet.extraConfig does not collide.
      msg = "an unset reservation is absent from the rendered configuration";
      cond =
        let
          cfg = consumer.config.nixosConfigurations.worker2.config.services.kubernetes.kubelet.extraConfig;
        in
        !(cfg ? systemReserved) && !(cfg ? kubeReserved) && !(cfg ? evictionHard);
    }
    {
      msg = "containerd raises the nofile limit containers inherit";
      cond =
        let
          limitOf =
            m:
            consumer.config.nixosConfigurations.${m}.config.systemd.services.containerd.serviceConfig.LimitNOFILE
              or null;
        in
        limitOf "worker1" == 1048576 && limitOf "cp1" == 1048576;
    }
    {
      msg = "node-exporter's port stays closed unless asked for";
      cond = !(lib.elem 9100 (firewallPortsOf consumer "worker1"));
    }
    {
      msg = "node-exporter.openFirewall opens its port on every kubelet machine";
      cond =
        let
          c = mkConsumer withNodeExporter;
        in
        lib.all (m: lib.elem 9200 (firewallPortsOf c m)) [
          "cp1"
          "worker1"
        ];
    }
    {
      msg = "extra containerd runtime handlers reach every kubelet";
      cond =
        let
          runtimesOf =
            m:
            consumer.config.nixosConfigurations.${m}.config.virtualisation.containerd.settings.plugins."io.containerd.grpc.v1.cri".containerd.runtimes
              or { };
          ok =
            m:
            (runtimesOf m).runc-cgroup-writable.cgroup_writable or false
            && (runtimesOf m).runc.runtime_type or null == "io.containerd.runc.v2";
        in
        ok "worker1" && ok "cp1";
    }
    {
      msg = "nix-snapshotter reaches only the machines that enable it";
      cond =
        let
          nodeOf = m: consumer.config.nixosConfigurations.${m}.config;
          snapshotterOf =
            m:
            (nodeOf m)
            .virtualisation.containerd.settings.plugins."io.containerd.grpc.v1.cri".containerd.snapshotter
              or null;
          imageService =
            m: lib.hasInfix "--image-service-endpoint" (nodeOf m).services.kubernetes.kubelet.extraOpts;
        in
        snapshotterOf "worker2" == "nix"
        &&
          (nodeOf "worker2").virtualisation.containerd.settings.proxy_plugins.nix.capabilities == [
            "remap-ids"
          ]
        && imageService "worker2"
        && (nodeOf "worker2").systemd.services.nix-snapshotter.enable
        && snapshotterOf "worker1" != "nix"
        && !(imageService "worker1");
    }
    {
      msg = "per-machine keepalived priorities survive the lowering";
      cond =
        (settingsOf "loadbalancer" "control-plane" "cp1").keepalivedPriority == 150
        && (settingsOf "loadbalancer" "control-plane" "cp3").keepalivedPriority == 50;
    }
    {
      msg = "the pinned Kubernetes minor reaches every kubelet";
      cond =
        (settingsOf "kubelet" "node" "worker1").kubernetesVersion == "1.36"
        && (settingsOf "kubelet" "node" "cp1").kubernetesVersion == "1.36";
    }
    {
      msg = "the version pin produces the kubepkgs package set";
      cond = lib.hasInfix "1.36" consumer.config.nixosConfigurations.cp1.config.services.kubernetes.package.name;
    }
    {
      msg = "the pinned Kubernetes minor reaches every etcd member";
      cond = (settingsOf "etcd" "member" "cp1").kubernetesVersion == "1.36";
    }
    {
      # Named outright, since "not nixpkgs' etcd" holds for every minor kubepkgs ships.
      msg = "the version pin reaches the etcd server and its tools";
      cond =
        let
          etcd = consumer.config.nixosConfigurations.cp1.config;
        in
        etcd.services.etcd.package == pinned.deps.etcd
        &&
          etcd.cluster.cairn.etcd.tools == [
            pinned.deps.etcdctl
            pinned.deps.etcdutl
          ];
    }
    {
      msg = "the pinned Kubernetes minor reaches every kubeconfig machine";
      cond = (settingsOf "kubeconfig" "node" "cp1").kubernetesVersion == "1.36";
    }
    {
      # nixpkgs' kubectl can drift past the one-minor kubectl skew.
      msg = "the version pin reaches the kubectl on the machine's PATH";
      cond =
        consumer.config.nixosConfigurations.cp1.config.cluster.cairn.kubeconfig.kubectl == pinned.kubectl;
    }
    {
      msg = "metrics-server bootstraps from the control-plane machines";
      cond = instances."metrics-server".roles.control-plane.machines ? cp1;
    }
    {
      # Named outright, since nixpkgs ships no metrics-server and a claim about the name holds for every minor.
      msg = "the pinned minor supplies the metrics-server image";
      cond =
        let
          ms = consumer.config.nixosConfigurations.cp1.config.cluster.cairn.metricsServer;
        in
        ms.package == pinned.sigs.metrics-server
        &&
          ms.nodeNames == [
            "cp1"
            "cp2"
            "cp3"
          ];
    }
    {
      msg = "the pinned minor supplies the CoreDNS image";
      cond =
        consumer.config.nixosConfigurations.cp1.config.cluster.cairn.coredns.package == pinned.deps.coredns;
    }
    {
      msg = "apiserver health checking reaches the loadbalancer and defaults on";
      cond = (settingsOf "loadbalancer" "control-plane" "cp1").healthCheck.enable;
    }
    {
      msg = "HAProxy probes backend readiness rather than TCP reachability";
      cond = lib.hasInfix "httpchk GET /readyz" consumer.config.nixosConfigurations.cp1.config.services.haproxy.config;
    }
    {
      msg = "keepalived tracks local apiserver readiness for the VIP election";
      cond =
        consumer.config.nixosConfigurations.cp1.config.services.keepalived.vrrpInstances.VI_K8S.trackScripts
        == [ "check_apiserver" ];
    }
    {
      msg = "cluster machines are excluded from bulk updates by default";
      cond =
        consumer.config.nixosConfigurations.cp1.config.clan.core.deployment.requireExplicitUpdate
        && consumer.config.nixosConfigurations.worker1.config.clan.core.deployment.requireExplicitUpdate;
    }
    {
      msg = "node labels carry each machine's role";
      cond =
        (settingsOf "inoculant" "node" "cp1").nodeLabels ? "node-role.kubernetes.io/control-plane"
        && (settingsOf "inoculant" "node" "worker1").nodeLabels ? "node-role.kubernetes.io/worker";
    }
    {
      msg = "machine node labels merge with the role label";
      cond =
        (settingsOf "inoculant" "node" "worker1").nodeLabels == {
          "node-role.kubernetes.io/worker" = "";
          "example.com/gpu" = "true";
        };
    }
    {
      # The merge above passes in either order, since the keys differ; overriding the role key pins it.
      msg = "a machine node label can override the role label";
      cond =
        let
          overridden = lowerSpec (
            exampleSpec
            // {
              machines = exampleSpec.machines // {
                worker2 = exampleSpec.machines.worker2 // {
                  nodeLabels."node-role.kubernetes.io/worker" = "override";
                };
              };
            }
          );
        in
        overridden.inventory.instances.inoculant.roles.node.machines.worker2.settings.nodeLabels == {
          "node-role.kubernetes.io/worker" = "override";
        };
    }
    {
      msg = "flux settings reach the control plane";
      cond = (settingsOf "flux" "control-plane" "cp1").branch == "main";
    }
    {
      msg = "machines are tagged by role";
      cond = lowered.inventory.machines.worker1.tags == [ "worker" ];
    }
    {
      # A value landing on a machine without the option needs no assertion, since the probe below would fail outright.
      msg = "NixOS-level options reach the machines that declare them";
      cond =
        let
          cp1 = consumer.config.nixosConfigurations.cp1.config.cluster.cairn;
        in
        cp1.apiServerPort == 6443 && cp1.coredns.replicas == 2 && cp1.etcd.initialClusterState == "new";
    }
    {
      # Workers first would put a kubelet ahead of its apiserver; the VIP holder goes last so the VIP moves once.
      msg = "the upgrade plan walks the control plane by ascending VIP priority, then workers";
      cond =
        map (m: m.machine) plan.machines == [
          "cp3"
          "cp2"
          "cp1"
          "worker1"
          "worker2"
        ];
    }
    {
      msg = "the upgrade plan drains workers but not master-only machines, and gates on the pinned minor";
      cond =
        let
          byName = lib.listToAttrs (map (m: lib.nameValuePair m.machine m) plan.machines);
        in
        !byName.cp1.drain
        && byName.cp1.etcd
        && byName.worker1.drain
        && !byName.worker1.etcd
        && byName.worker1.kubernetesVersion == "1.36"
        && byName.worker1.targetHost == "root@10.10.0.21"
        && plan.apiserverPort == 6444;
    }
    {
      # NixOS defaults this to false, which rejects every CSI node plugin and Ceph OSD at admission.
      msg = "apiserver machines allow privileged pods by default";
      cond = consumer.config.nixosConfigurations.cp1.config.services.kubernetes.apiserver.allowPrivileged;
    }
  ];

  failures = map (e: e.msg) (lib.filter (e: !e.cond) expectations);

  # A control-plane and a worker machine cover both kubelet roles and the whole export chain.
  # String context is discarded to stay an evaluation check, and nothing pki-derived is probed, since those are clan vars paths that exist only after `clan vars generate`.
  probe =
    map
      (
        machine:
        let
          node = consumer.config.nixosConfigurations.${machine}.config;
        in
        {
          inherit (node.services.kubernetes) roles;
          haproxy = builtins.unsafeDiscardStringContext "${toString node.services.haproxy.config}";
          etcd = node.services.etcd.initialCluster;
          apiServerURL = node.cluster.cairn.apiServerURL;
        }
      )
      [
        "cp1"
        "worker1"
      ];
in
lib.throwIf (failures != [ ])
  "checks/flake-module.nix: the lowering no longer holds: ${lib.concatStringsSep "; " failures}"
  (
    pkgs.runCommand "cairn-flake-module" { } ''
      ${builtins.deepSeq probe ":"}
      ${lib.getExe cairn-upgrade} --plan ${planFile} --dry-run > dry-run
      cat dry-run
      grep -q '^cp3 (control-plane; etcd,apiserver,kubelet)$' dry-run
      grep -q 'cordon and drain worker1' dry-run
      if grep -q 'cordon and drain cp' dry-run; then
        echo "dry run drains a master-only machine" >&2
        exit 1
      fi
      touch "$out"
    ''
  )
