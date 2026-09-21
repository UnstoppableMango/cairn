# Coverage for `flakeModules.default`'s `cairn.clusters` interface: the option
# tree in flakeModules/cluster/options.nix and the lowering in
# flakeModules/cluster/lower.nix.
#
# Nothing else in CI touches them. The single-node VM test writes its
# inventory by hand (that's the point of it), and examples/ha-cluster is a
# separate flake `nix flake check` never descends into, so without this the
# whole interface could break unnoticed.
#
# Evaluation-only, like ./consumer-services.nix and for the same reasons: the
# lowering's output is an inventory, and the thing worth proving is that clan
# accepts it and that the settings land where they should. Booting five
# machines would prove nothing further about this file's subject.
{
  # Cairn's `clan.modules` registry, i.e. what a consumer flake sees as
  # `inputs.cairn.clan.modules`.
  cairnModules,
  clan-core,
  nixpkgs,
  kubepkgs,
  pkgs,
  lib,
}:
let
  inherit (pkgs.stdenv.hostPlatform) system;

  # The exact release the example pins, so the assertions below can name the
  # derivations a pinned machine must end up with rather than describe them.
  pinned = kubepkgs.legacyPackages.${system}.kubernetes."1.36";

  cairnLib = import ../lib { inherit lib; };

  # Run the example's spec through the option tree exactly as flake-parts
  # would, so defaults and types apply, then lower it. Going through
  # `evalModules` directly rather than `flake-parts.lib.mkFlake` keeps this to
  # the two files under test.
  exampleSpec = import ../examples/ha-cluster/cluster.nix {
    inherit system;
    moduleInput = "cairn";
  };

  lowerSpec =
    spec:
    import ../flakeModules/cluster/lower.nix { inherit lib cairnLib; }
      {
        name = "example";
        multi = false;
      }
      (lib.evalModules {
        modules = [
          { options.cairn = import ../flakeModules/cluster/options.nix { inherit lib; }; }
          { cairn.clusters.example = spec; }
        ];
      }).config.cairn.clusters.example;

  lowered = lowerSpec exampleSpec;

  # Same stand-in for a downstream consumer flake as ./consumer-services.nix:
  # clan reads `config.self.inputs` to resolve `module.input = "cairn"`.
  consumer = clan-core.lib.clan {
    self.inputs = {
      cairn.clan.modules = cairnModules;
      inherit nixpkgs;
    };

    directory = ./.;

    imports = [ lowered ];

    inventory.meta.name = "cairn-flake-module";
  };

  inherit (lowered.inventory) instances;

  settingsOf =
    instance: role: machine:
    instances.${instance}.roles.${role}.machines.${machine}.settings;

  # Facts about the lowering that a typo would silently change. Written as
  # assertions rather than probes because each is a specific claim about what
  # ./cluster/lower.nix produced.
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
      # Workers take pods; control-plane machines are nodes without being
      # scheduling targets, unless `machines.<name>.schedulable` says so.
      msg = "schedulability follows the machine's role";
      cond =
        (settingsOf "kubelet" "node" "worker1").schedulable
        && !(settingsOf "kubelet" "node" "cp1").schedulable;
    }
    {
      # A machine's own cap wins; everything else takes the cluster value,
      # which is kubelet's 110 until the cluster says otherwise.
      msg = "a per-machine maxPods overrides the cluster default";
      cond =
        (settingsOf "kubelet" "node" "worker1").maxPods == 250
        && (settingsOf "kubelet" "node" "worker2").maxPods == 110
        && (settingsOf "kubelet" "node" "cp1").maxPods == 110;
    }
    {
      # The role setting has to reach the KubeletConfiguration file, not stop
      # at the inventory.
      msg = "maxPods reaches the rendered kubelet configuration";
      cond =
        consumer.config.nixosConfigurations.worker1.config.services.kubernetes.kubelet.extraConfig.maxPods
        == 250;
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
      # The kubepkgs-built symlinkJoin lands as the machine's combined
      # Kubernetes package. Evaluation-only: the derivation is never built.
      msg = "the version pin produces the kubepkgs package set";
      cond = lib.hasInfix "1.36" consumer.config.nixosConfigurations.cp1.config.services.kubernetes.package.name;
    }
    {
      msg = "the pinned Kubernetes minor reaches every etcd member";
      cond = (settingsOf "etcd" "member" "cp1").kubernetesVersion == "1.36";
    }
    {
      # The member's etcd is the pinned minor's, named outright: a weaker
      # claim (an etcd that is not nixpkgs') also holds for every other minor
      # kubepkgs ships. Evaluation-only; the derivations are never built.
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
      # The kubectl on an operator's PATH is the pinned minor's, not nixpkgs',
      # which can drift past the one-minor kubectl skew.
      msg = "the version pin reaches the kubectl on the machine's PATH";
      cond =
        consumer.config.nixosConfigurations.cp1.config.cluster.cairn.kubeconfig.kubectl == pinned.kubectl;
    }
    {
      msg = "metrics-server bootstraps from the control-plane machines";
      cond = instances."metrics-server".roles.control-plane.machines ? cp1;
    }
    {
      # The addon's image is built from the pinned minor's metrics-server,
      # named outright: nixpkgs ships none, so a weaker claim about the
      # package's name holds for every minor kubepkgs has.
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
      # worker1 sets nodeLabels in examples/ha-cluster; the role label has to
      # survive alongside it rather than being replaced by it.
      msg = "machine node labels merge with the role label";
      cond =
        (settingsOf "inoculant" "node" "worker1").nodeLabels == {
          "node-role.kubernetes.io/worker" = "";
          "example.com/gpu" = "true";
        };
    }
    {
      # The merge above passes either way round, since the two keys differ.
      # Overriding the role key is what pins the order: the machine wins.
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
      # The other half of the surface: options no inventory setting reaches,
      # emitted as NixOS config onto the machines whose roles declare them.
      # The mirror image — a value landing on a machine that has no such
      # option — needs no assertion here, since the probe below evaluates
      # both machines and would fail outright.
      msg = "NixOS-level options reach the machines that declare them";
      cond =
        let
          cp1 = consumer.config.nixosConfigurations.cp1.config.cluster.cairn;
        in
        cp1.apiServerPort == 6443 && cp1.coredns.replicas == 2 && cp1.etcd.initialClusterState == "new";
    }
    {
      # NixOS defaults this to false, which rejects every CSI node plugin and
      # Ceph OSD daemon at admission. Assert the whole path, since the value
      # only matters where it lands on services.kubernetes.
      msg = "apiserver machines allow privileged pods by default";
      cond = consumer.config.nixosConfigurations.cp1.config.services.kubernetes.apiserver.allowPrivileged;
    }
  ];

  failures = map (e: e.msg) (lib.filter (e: !e.cond) expectations);

  # Force clan's own view of the generated inventory: a control-plane and a
  # worker machine, so both kubelet roles and the whole dependency chain
  # (pki → etcd/apiserver exports → loadbalancer backends) actually resolve.
  #
  # String context is discarded so this stays an evaluation check, and
  # nothing pki-derived is probed: those resolve to clan vars paths that only
  # exist after `clan vars generate`.
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
      touch "$out"
    ''
  )
