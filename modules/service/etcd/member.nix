{ cairnLib }:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.cluster.cairn.etcd;
  pki = config.cluster.cairn.pki;

  localHosts = [
    cfg.advertiseAddress
    "127.0.0.1"
  ];

  etcdPeerEndpoints = map (n: "${n.name}=https://${n.ip}:2380") cfg.nodes;

  selfPeerUrl = "https://${cfg.advertiseAddress}:2380";

  # Written by the join and read back by etcd as an `EnvironmentFile`, which
  # systemd applies after the unit's `Environment=` lines and so wins over the
  # declarative `initialCluster`. On tmpfs, so a machine that is reinstalled
  # starts from a fresh join rather than a stale membership.
  initialClusterEnvFile = "/run/etcd-autojoin.env";

  # Every other member's client URL. The machine's own is useless for joining:
  # the point is to reach a member that is already in the cluster, and this one
  # is not serving yet when the join runs.
  joinEndpoints = lib.concatMapStringsSep "," (n: "https://${n.ip}:2379") (
    lib.filter (n: n.ip != cfg.advertiseAddress) cfg.nodes
  );

  # The units carry the credentials rather than the scripts, so the scripts
  # close over no clan vars. A var's path only resolves once `clan vars
  # generate` has run, and a script holding one cannot be built by an
  # evaluation-only check (see checks/etcd-autojoin.nix).
  #
  # `etcd-client-cert` is owned by `kubernetes` while the etcd unit runs as
  # `etcd`, so whatever reads the key has to be root.
  etcdctlCredentials = {
    ETCDCTL_API = "3";
    ETCDCTL_CACERT = pki.ca.cert;
    ETCDCTL_CERT = pki.certs."etcd-client-cert".cert;
    ETCDCTL_KEY = pki.certs."etcd-client-cert".key;
  };

  # Registers this machine with a running cluster before its etcd starts.
  #
  # Joining as a learner rather than a voting member is what makes this safe to
  # run unattended: a voting member counts toward quorum from the moment it is
  # added, so adding one to a healthy three-member cluster leaves four members
  # needing three votes and no failures tolerated until this machine finishes
  # booting. A learner never counts toward quorum.
  autoJoinScript = pkgs.writeShellApplication {
    name = "etcd-autojoin";
    runtimeInputs = cfg.tools;
    text = ''
      # An initialised data directory means this machine is already a member and
      # etcd rejoins on its own. Returning here without contacting anyone is
      # deliberate: a whole cluster booting at once has no reachable peer yet,
      # and blocking on one would keep every member down.
      if [ -d ${lib.escapeShellArg config.services.etcd.dataDir}/member ]; then
        echo "etcd data directory is initialised; nothing to register"
        exit 0
      fi

      IFS=',' read -r -a candidates <<< ${lib.escapeShellArg joinEndpoints}

      endpoint=""
      for candidate in "''${candidates[@]}"; do
        [ -n "$candidate" ] || continue
        if etcdctl --endpoints="$candidate" endpoint health >/dev/null 2>&1; then
          endpoint="$candidate"
          break
        fi
      done

      if [ -z "$endpoint" ]; then
        echo "no existing etcd member answered; refusing to join a cluster that is not there" >&2
        exit 1
      fi

      if etcdctl --endpoints="$endpoint" member list \
        | grep -qF ${lib.escapeShellArg selfPeerUrl}; then
        echo "this machine is already a member but its data directory is empty." >&2
        echo "etcd cannot rejoin under an existing member ID with no data. Recovery is" >&2
        echo "'etcdctl member remove' followed by a fresh join, and removing a member is" >&2
        echo "destructive, so it is left to an operator." >&2
        exit 1
      fi

      echo "registering ${config.networking.hostName} as a learner via $endpoint"
      added=$(etcdctl --endpoints="$endpoint" member add ${lib.escapeShellArg config.networking.hostName} \
        --peer-urls=${lib.escapeShellArg selfPeerUrl} --learner)
      printf '%s\n' "$added"

      # etcd validates this machine's initial cluster against the membership it
      # reads back from a peer and refuses to start on a count mismatch
      # ("member count is unequal", ValidateClusterAndAssignIDs). The
      # declarative `initialCluster` lists every machine in the inventory, which
      # is wrong the moment more than one of them has yet to join. `member add`
      # prints the membership that this machine must actually claim, so take it
      # from there.
      initial_cluster=$(printf '%s\n' "$added" | grep '^ETCD_INITIAL_CLUSTER=' || true)

      if [ -z "$initial_cluster" ]; then
        echo "member add printed no ETCD_INITIAL_CLUSTER to start from" >&2
        exit 1
      fi

      # Peer URLs rather than anything secret, and systemd reads it as root.
      printf '%s\n' "$initial_cluster" > ${lib.escapeShellArg initialClusterEnvFile}
    '';
  };

  # Promotes the learner once its log has caught up. etcd rejects the promotion
  # until then, so failing and letting systemd retry is the whole mechanism.
  #
  # Both calls go to the other members, whose client URLs the unit passes as
  # the first argument. A learner answers only `Status` and serializable reads,
  # refusing `MemberList` and `MemberPromote` alike with "rpc not supported for
  # learner", so asking this machine's own etcd would retry forever.
  promoteScript = pkgs.writeShellApplication {
    name = "etcd-promote";
    runtimeInputs = cfg.tools;
    text = ''
      export ETCDCTL_ENDPOINTS="$1"

      line=$(etcdctl member list | grep -F ${lib.escapeShellArg selfPeerUrl} || true)

      if [ -z "$line" ]; then
        echo "not a member yet; retrying" >&2
        exit 1
      fi

      if [ "$(printf '%s' "$line" | awk -F',' '{gsub(/ /, "", $NF); print $NF}')" != "true" ]; then
        echo "already a voting member"
        exit 0
      fi

      echo "promoting learner $(printf '%s' "$line" | cut -d, -f1)"
      etcdctl member promote "$(printf '%s' "$line" | cut -d, -f1)"
    '';
  };

  # Removes the members named in `removedMembers` that are still registered,
  # and does nothing once none are. Every remaining member runs it, so the first
  # to get there does the removal and the rest find nothing left to remove.
  #
  # The endpoints are the other members' client URLs, passed as the first
  # argument, for the same reason as the promote: this machine may itself be a
  # learner, which refuses `MemberList`. A removal that would lose quorum is
  # refused by etcd itself (`--strict-reconfig-check`, on by default).
  removeScript = pkgs.writeShellApplication {
    name = "etcd-remove-members";
    runtimeInputs = cfg.tools;
    text = ''
      export ETCDCTL_ENDPOINTS="$1"
      shift

      members=$(etcdctl member list)

      for name in "$@"; do
        # `member list` prints `ID, status, name, peer URLs, client URLs,
        # is learner`. A member added but never started has an empty name and
        # cannot be matched; `etcdctl member remove <ID>` is the way out there.
        id=$(printf '%s\n' "$members" | awk -F', ' -v name="$name" '$3 == name { print $1 }')

        if [ -z "$id" ]; then
          echo "$name is not a member; nothing to remove"
          continue
        fi

        echo "removing member $name ($id)"
        etcdctl member remove "$id"
      done
    '';
  };

  removedButListed = lib.intersectLists cfg.removedMembers (map (n: n.name) cfg.nodes);

  autoJoinEnabled = cfg.autoJoin && cfg.initialClusterState == "existing";
in
{
  imports = [
    ../identity.nix
    ../etcd-client.nix
  ];

  options.cluster.cairn.etcd = {
    nodes = cairnLib.options.mkNodes "All etcd member nodes with their names and IPs.";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.etcd;
      defaultText = lib.literalExpression "pkgs.etcd";
      description = "etcd server this member runs. A pinned Kubernetes minor supplies the matching etcd; see version.nix.";
    };

    tools = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      default = [ cfg.package ];
      defaultText = lib.literalExpression "[ config.cluster.cairn.etcd.package ]";
      description = "Packages putting etcdctl and etcdutl on the member's PATH. nixpkgs ships them inside the server package; kubepkgs builds them separately.";
    };

    advertiseAddress = lib.mkOption {
      type = lib.types.str;
      description = "IP address this node advertises for etcd client/peer traffic.";
    };

    initialClusterState = lib.mkOption {
      type = lib.types.enum [
        "new"
        "existing"
      ];
      default = "new";
      description = "etcd initial cluster state; set to \"existing\" when replacing a member or restoring into a live cluster.";
    };

    autoJoin = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Register this machine with the running cluster before etcd starts,
        instead of requiring `etcdctl member add` by hand. Only has an effect
        alongside `initialClusterState = "existing"`, which is the case that
        needs it: etcd refuses to start in that state until the member exists.

        The machine joins as a raft learner and is promoted to a voting member
        once its log has caught up, so a join never lowers the quorum the
        cluster can survive, however long this machine takes to come up.

        A machine whose data directory is empty while it is still listed as a
        member is left alone and reported, since recovering that needs
        `etcdctl member remove`, which destroys the member's data.
      '';
    };

    removedMembers = lib.mkOption {
      type = lib.types.listOf lib.types.nonEmptyStr;
      default = [ ];
      example = [ "old-node" ];
      description = ''
        Names of etcd members to remove from the running cluster, for machines
        that have left the inventory. Every remaining member runs
        `etcd-remove-members.service`, which removes those still registered
        and does nothing once none are, so the name can stay listed until every
        member has been deployed and then be dropped.

        A member is never removed for being absent from the inventory alone: a
        machine that has just joined is absent from the configuration of every
        member not yet redeployed, so only names listed here are touched. A
        name still in the inventory is rejected by an assertion.
      '';
    };
  };

  config = {
    cluster.cairn.pki.certs = {
      etcd-server-cert = {
        cn = "etcd-server";
        hosts = localHosts;
        share = false;
        profile = "server";
        owner = "etcd";
      };
      etcd-peer-cert = {
        cn = "etcd-peer";
        hosts = localHosts;
        share = false;
        profile = "peer";
        owner = "etcd";
      };
    };

    services.etcd = {
      inherit (cfg) package;
      # The inventory machine name is the machine's hostname, so this matches
      # the name this node is listed under in `initialCluster`.
      name = config.networking.hostName;
      listenClientUrls = [ "https://0.0.0.0:2379" ];
      listenPeerUrls = [ "https://0.0.0.0:2380" ];
      advertiseClientUrls = [ "https://${cfg.advertiseAddress}:2379" ];
      initialAdvertisePeerUrls = [ "https://${cfg.advertiseAddress}:2380" ];
      initialCluster = etcdPeerEndpoints;
      initialClusterState = cfg.initialClusterState;
      initialClusterToken = config.cluster.cairn.clusterName;
      clientCertAuth = true;
      peerClientCertAuth = true;
      trustedCaFile = pki.ca.cert;
      certFile = pki.certs."etcd-server-cert".cert;
      keyFile = pki.certs."etcd-server-cert".key;
      peerCertFile = pki.certs."etcd-peer-cert".cert;
      peerKeyFile = pki.certs."etcd-peer-cert".key;
      peerTrustedCaFile = pki.ca.cert;
    };

    # The `+` prefix runs the hook as root rather than the unit's `etcd` user,
    # which cannot read the `kubernetes`-owned client key. Failing here keeps
    # etcd from starting, which is what should happen when the registration
    # this machine needs did not land.
    systemd.services.etcd = lib.mkIf autoJoinEnabled {
      environment = etcdctlCredentials;
      serviceConfig = {
        ExecStartPre = [ "+${lib.getExe autoJoinScript}" ];
        # Optional: a machine that already holds data skips the join and writes
        # no file, and etcd ignores `initialCluster` once it has a WAL anyway.
        EnvironmentFile = "-${initialClusterEnvFile}";
      };
    };

    systemd.services.etcd-promote = lib.mkIf autoJoinEnabled {
      description = "Promote this etcd learner to a voting member";
      after = [ "etcd.service" ];
      requires = [ "etcd.service" ];
      wantedBy = [ "multi-user.target" ];
      environment = etcdctlCredentials;
      serviceConfig = {
        Type = "oneshot";
        # An argument rather than an `environment` entry, so an evaluation-only
        # check can read it: `environment` also carries the clan var paths.
        ExecStart = "${lib.getExe promoteScript} ${lib.escapeShellArg joinEndpoints}";
        # etcd rejects the promotion until the learner has caught up, so the
        # retry is the mechanism rather than a failure path. A separate unit
        # runs as root already and needs no `+`.
        Restart = "on-failure";
        RestartSec = "15s";
      };
      unitConfig.StartLimitIntervalSec = 0;
    };

    assertions = [
      {
        assertion = removedButListed == [ ];
        message = "cluster.cairn.etcd.removedMembers names machines that are still etcd members: ${lib.concatStringsSep ", " removedButListed}";
      }
    ];

    systemd.services.etcd-remove-members = lib.mkIf (cfg.removedMembers != [ ]) {
      description = "Remove departed members from the etcd cluster";
      after = [ "etcd.service" ];
      requires = [ "etcd.service" ];
      wantedBy = [ "multi-user.target" ];
      environment = etcdctlCredentials;
      serviceConfig = {
        Type = "oneshot";
        # Arguments rather than `environment` entries, for the same reason as
        # the promote unit's.
        ExecStart = lib.escapeShellArgs (
          [
            (lib.getExe removeScript)
            joinEndpoints
          ]
          ++ cfg.removedMembers
        );
        # Retried rather than failed for good, since the other members may
        # still be starting, or etcd may refuse the removal until enough of
        # them are back to keep quorum.
        Restart = "on-failure";
        RestartSec = "30s";
      };
      unitConfig.StartLimitIntervalSec = 0;
    };

    networking.firewall.allowedTCPPorts = [
      2379
      2380
    ];

    environment.systemPackages = cfg.tools;

    environment.variables = {
      ETCDCTL_ENDPOINTS = "https://127.0.0.1:2379";
      ETCDCTL_CACERT = pki.ca.cert;
      ETCDCTL_CERT = pki.certs."etcd-client-cert".cert;
      ETCDCTL_KEY = pki.certs."etcd-client-cert".key;
    };
  };
}
