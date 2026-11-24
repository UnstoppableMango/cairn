# Two properties asserted here otherwise fail only at runtime, and silently.
# The hook must run as root, since the etcd user cannot read the `kubernetes`-owned client key.
# The endpoint list must exclude the joining machine, which is not serving yet and can stall the join.
# Building the script also runs the shellcheck `writeShellApplication` does, which nothing else in CI would.
{
  cairnModules,
  clan-core,
  lib,
  nixpkgs,
  pkgs,
}:
let
  inherit (pkgs.stdenv.hostPlatform) system;

  clusterName = "etcd-autojoin";
  joinIp = "10.20.0.1";
  newIp = "10.20.0.2";
  offIp = "10.20.0.3";

  mkModule = name: {
    module.name = "@UnstoppableMango/${name}";
    module.input = "cairn";
  };

  consumer = clan-core.lib.clan {
    self.inputs = {
      cairn.clan.modules = cairnModules;
      inherit nixpkgs;
    };

    directory = ./.;

    inventory.meta.name = clusterName;

    inventory.machines = {
      join1.tags = [ "etcd" ];
      new1.tags = [ "etcd" ];
      off1.tags = [ "etcd" ];
    };

    inventory.instances = {
      pki = mkModule "pki" // {
        roles.node.tags.all = { };
      };

      etcd = mkModule "etcd" // {
        roles.member.machines = {
          join1.settings = {
            ip = joinIp;
            inherit clusterName;
          };
          new1.settings = {
            ip = newIp;
            inherit clusterName;
          };
          off1.settings = {
            ip = offIp;
            inherit clusterName;
          };
        };
      };
    };

    # Every machine is a member, so the endpoint-exclusion assertion has something to exclude.
    machines.join1 = {
      nixpkgs.hostPlatform = system;
      cluster.cairn.etcd = {
        autoJoin = true;
        initialClusterState = "existing";
        removedMembers = [ "gone1" ];
      };
    };

    # `autoJoin` alone does nothing: a `new` cluster has nobody to register with.
    # new1 names a machine still in the inventory, which the assertion rejects.
    machines.new1 = {
      nixpkgs.hostPlatform = system;
      cluster.cairn.etcd = {
        autoJoin = true;
        initialClusterState = "new";
        removedMembers = [ "off1" ];
      };
    };

    machines.off1 = {
      nixpkgs.hostPlatform = system;
      cluster.cairn.etcd.initialClusterState = "existing";
    };
  };

  join1 = consumer.config.nixosConfigurations.join1.config;
  new1 = consumer.config.nixosConfigurations.new1.config;
  off1 = consumer.config.nixosConfigurations.off1.config;

  preStartOf = machine: machine.systemd.services.etcd.serviceConfig.ExecStartPre or [ ];

  joinPreStart = lib.head (preStartOf join1);

  joinScript = lib.removePrefix "+" joinPreStart;

  removeExecStart = join1.systemd.services.etcd-remove-members.serviceConfig.ExecStart;

  failedAssertions = machine: map (a: a.message) (lib.filter (a: !a.assertion) machine.assertions);

  probe = {
    rootPrefixed =
      assert lib.length (preStartOf join1) == 1;
      assert lib.hasPrefix "+" joinPreStart;
      joinPreStart;

    initialClusterOverride =
      assert join1.systemd.services.etcd.serviceConfig.EnvironmentFile == "-/run/etcd-autojoin.env";
      join1.systemd.services.etcd.serviceConfig.EnvironmentFile;

    promoteUnit =
      assert join1.systemd.services.etcd-promote.serviceConfig.Restart == "on-failure";
      assert join1.systemd.services.etcd-promote.unitConfig.StartLimitIntervalSec == 0;
      # A first start that times out must not strand the learner.
      assert lib.elem "etcd.service" join1.systemd.services.etcd-promote.wantedBy;
      join1.systemd.services.etcd-promote.serviceConfig.Type;

    promoteViaPeers =
      let
        execStart = join1.systemd.services.etcd-promote.serviceConfig.ExecStart;
        peer = "https://${newIp}:2379";
        self = "https://${joinIp}:2379";
      in
      assert lib.hasInfix peer execStart;
      assert !(lib.hasInfix "127.0.0.1" execStart);
      assert !(lib.hasInfix self execStart);
      execStart;

    removeViaPeers =
      assert join1.systemd.services.etcd-remove-members.serviceConfig.Restart == "on-failure";
      assert lib.elem "etcd.service" join1.systemd.services.etcd-remove-members.wantedBy;
      assert lib.hasInfix "https://${newIp}:2379" removeExecStart;
      assert !(lib.hasInfix "https://${joinIp}:2379" removeExecStart);
      assert lib.hasInfix "gone1" removeExecStart;
      removeExecStart;

    removeRejectsMembers =
      assert lib.any (lib.hasInfix "still etcd members: off1") (failedAssertions new1);
      # Only this module's assertion: an evaluation with no file systems or boot loader fails some of NixOS's own.
      assert !(lib.any (lib.hasInfix "removedMembers") (failedAssertions join1));
      true;

    removeOffByDefault =
      assert !(off1.systemd.services ? etcd-remove-members);
      off1.cluster.cairn.etcd.removedMembers;

    newClusterUntouched =
      assert preStartOf new1 == [ ];
      assert !(new1.systemd.services ? etcd-promote);
      new1.services.etcd.initialClusterState;

    defaultUntouched =
      assert preStartOf off1 == [ ];
      assert !(off1.systemd.services ? etcd-promote);
      off1.cluster.cairn.etcd.autoJoin;
  };
in
pkgs.runCommand "cairn-etcd-autojoin" { } ''
  ${builtins.deepSeq probe ":"}

  # Realising the script runs shellcheck.
  script=${joinScript}
  : ${lib.escapeShellArg removeExecStart}

  grep -q -- '--learner' "$script" \
    || { echo "join does not add the member as a learner" >&2; exit 1; }

  grep -q 'ETCD_INITIAL_CLUSTER=' "$script" \
    || { echo "join does not record the initial cluster member add reports" >&2; exit 1; }

  grep -q '/run/etcd-autojoin.env' "$script" \
    || { echo "join does not write the file the unit reads" >&2; exit 1; }

  grep -q 'https://${newIp}:2379' "$script" \
    || { echo "join endpoints are missing a peer" >&2; exit 1; }

  if grep -q 'https://${joinIp}:2379' "$script"; then
    echo "join endpoints include the joining machine's own address" >&2
    exit 1
  fi

  touch "$out"
''
