# Coverage for `cluster.cairn.etcd.autoJoin`, which registers a machine with a
# running cluster before its etcd starts.
#
# Two of the properties asserted here fail only at runtime otherwise, and both
# are silent:
#
#   - The hook must run as root. `etcd-client-cert` is owned by `kubernetes`
#     while the etcd unit runs as `etcd`, so without systemd's `+` prefix the
#     hook cannot read the key it authenticates with.
#   - The endpoint list must exclude the joining machine's own address. It is
#     not serving when the hook runs, so an endpoint list containing it can
#     stall the join behind a connection that will never succeed.
#
# Building the script also puts it through the shellcheck that
# `writeShellApplication` runs, which nothing else in CI would.
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

    # The three states the option can be in. Every machine is an etcd member,
    # so each one's `nodes` lists all three and the endpoint-exclusion
    # assertion below has something to exclude.
    machines.join1 = {
      nixpkgs.hostPlatform = system;
      cluster.cairn.etcd = {
        autoJoin = true;
        initialClusterState = "existing";
      };
    };

    # `autoJoin` alone does nothing: a `new` cluster bootstraps from
    # `initialCluster` and has nobody to register with.
    machines.new1 = {
      nixpkgs.hostPlatform = system;
      cluster.cairn.etcd = {
        autoJoin = true;
        initialClusterState = "new";
      };
    };

    # The default, proving existing consumers are untouched.
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

  # The script itself, with systemd's root-prefix stripped back off.
  joinScript = lib.removePrefix "+" joinPreStart;

  probe = {
    # The hook exists, and runs as root rather than as the unit's `etcd` user.
    rootPrefixed =
      assert lib.length (preStartOf join1) == 1;
      assert lib.hasPrefix "+" joinPreStart;
      joinPreStart;

    # etcd refuses to start when its initial cluster does not match the
    # membership a peer reports, and the declarative list names every machine
    # in the inventory including ones that have not joined. The join writes the
    # membership `member add` reports instead, and systemd applies an
    # `EnvironmentFile` after the unit's `Environment=` lines, so that value is
    # the one etcd sees. Optional, since a machine with data skips the join.
    initialClusterOverride =
      assert join1.systemd.services.etcd.serviceConfig.EnvironmentFile == "-/run/etcd-autojoin.env";
      join1.systemd.services.etcd.serviceConfig.EnvironmentFile;

    # ...and the promote unit that turns the learner into a voting member.
    promoteUnit =
      assert join1.systemd.services.etcd-promote.serviceConfig.Restart == "on-failure";
      assert join1.systemd.services.etcd-promote.unitConfig.StartLimitIntervalSec == 0;
      join1.systemd.services.etcd-promote.serviceConfig.Type;

    # A learner refuses `MemberList` and `MemberPromote`, so the promote has to
    # go to the other members and never to this machine's own etcd.
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

    # A `new` cluster gets no hook, and neither does the default.
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

  # Referencing the script realises it, which is what runs shellcheck.
  script=${joinScript}

  grep -q -- '--learner' "$script" \
    || { echo "join does not add the member as a learner" >&2; exit 1; }

  # The membership etcd must claim comes from `member add`, not from the
  # declarative list, which names machines that have not joined yet.
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
