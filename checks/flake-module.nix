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
  pkgs,
  lib,
}:
let
  inherit (pkgs.stdenv.hostPlatform) system;

  cairnLib = import ../lib { inherit lib; };

  # Run the example's spec through the option tree exactly as flake-parts
  # would, so defaults and types apply, then lower it. Going through
  # `evalModules` directly rather than `flake-parts.lib.mkFlake` keeps this to
  # the two files under test.
  evaluated =
    (lib.evalModules {
      modules = [
        { options.cairn = import ../flakeModules/cluster/options.nix { inherit lib; }; }
        {
          cairn.clusters.example = import ../examples/ha-cluster/cluster.nix {
            inherit system;
            moduleInput = "cairn";
          };
        }
      ];
    }).config.cairn.clusters.example;

  lowered = import ../flakeModules/cluster/lower.nix { inherit lib cairnLib; } {
    name = "example";
    multi = false;
  } evaluated;

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
      msg = "kubelet splits across both of its roles";
      cond =
        lib.attrNames instances.kubelet.roles.control-plane.machines == [
          "cp1"
          "cp2"
          "cp3"
        ]
        &&
          lib.attrNames instances.kubelet.roles.worker.machines == [
            "worker1"
            "worker2"
          ];
    }
    {
      msg = "workers carry the cluster-wide settings the control plane would otherwise supply";
      cond = (settingsOf "kubelet" "worker" "worker1").vip == "10.10.0.10";
    }
    {
      msg = "per-machine keepalived priorities survive the lowering";
      cond =
        (settingsOf "loadbalancer" "control-plane" "cp1").keepalivedPriority == 150
        && (settingsOf "loadbalancer" "control-plane" "cp3").keepalivedPriority == 50;
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
      msg = "node labels default from each machine's role";
      cond =
        (settingsOf "inoculant" "node" "cp1").nodeLabels ? "node-role.kubernetes.io/control-plane"
        && (settingsOf "inoculant" "node" "worker1").nodeLabels ? "node-role.kubernetes.io/worker";
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
