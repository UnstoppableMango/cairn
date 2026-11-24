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

  # Read by etcd as an `EnvironmentFile`, which systemd applies after `Environment=`, so it wins over the declarative `initialCluster`.
  # On tmpfs, so a reinstalled machine starts from a fresh join rather than a stale membership.
  initialClusterEnvFile = "/run/etcd-autojoin.env";

  # This machine's own etcd is not serving yet when the join runs.
  joinEndpoints = lib.concatMapStringsSep "," (n: "https://${n.ip}:2379") (
    lib.filter (n: n.ip != cfg.advertiseAddress) cfg.nodes
  );

  # systemd's default unit PATH has no awk, and without it every parse read a learner as already voting.
  scriptTools = with pkgs; [
    coreutils
    gawk
    gnugrep
  ];

  # The units carry the credentials so the scripts close over no clan vars, whose paths resolve only after `clan vars generate` and would break the evaluation-only checks/etcd-autojoin.nix.
  # The client key is owned by `kubernetes`, so a unit reading it runs as root.
  # No `ETCDCTL_API`: etcdctl 3.6 warns about it on every call.
  etcdctlCredentials = {
    ETCDCTL_CACERT = pki.ca.cert;
    ETCDCTL_CERT = pki.certs."etcd-client-cert".cert;
    ETCDCTL_KEY = pki.certs."etcd-client-cert".key;
  };

  # Joins as a learner because a voting member counts toward quorum from the moment it is added: a healthy three-member cluster would need three of four votes until this machine finishes booting.
  autoJoinScript = pkgs.writeShellApplication {
    name = "etcd-autojoin";
    runtimeInputs = cfg.tools ++ scriptTools;
    text = ''
      # Already a member, so etcd rejoins on its own.
      # No peer is contacted, since a whole cluster booting at once has none reachable yet.
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

      # etcd refuses to start when its initial cluster's member count differs from a peer's ("member count is unequal").
      # The declarative `initialCluster` lists the whole inventory, which is wrong once more than one machine has yet to join, so take the membership `member add` prints.
      initial_cluster=$(printf '%s\n' "$added" | grep '^ETCD_INITIAL_CLUSTER=' || true)

      if [ -z "$initial_cluster" ]; then
        echo "member add printed no ETCD_INITIAL_CLUSTER to start from" >&2
        exit 1
      fi

      printf '%s\n' "$initial_cluster" > ${lib.escapeShellArg initialClusterEnvFile}
    '';
  };

  # etcd rejects the promotion until the learner has caught up, so systemd's retry is the mechanism.
  # The calls go to the other members, since a learner refuses `MemberList` and `MemberPromote` with "rpc not supported for learner".
  promoteScript = pkgs.writeShellApplication {
    name = "etcd-promote";
    runtimeInputs = cfg.tools ++ scriptTools;
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

  # Every remaining member runs this, and the first to get there does the removal.
  # The endpoints are the other members, since this machine may be a learner.
  # etcd itself refuses a removal that would lose quorum (`--strict-reconfig-check`).
  removeScript = pkgs.writeShellApplication {
    name = "etcd-remove-members";
    runtimeInputs = cfg.tools ++ scriptTools;
    text = ''
      export ETCDCTL_ENDPOINTS="$1"
      shift

      members=$(etcdctl member list)

      for name in "$@"; do
        # A member added but never started has an empty name and cannot be matched here; remove it by ID.
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

  # Credentials as wrapper defaults rather than global variables, which `sudo` resets and a non-login shell never reads.
  # No endpoint, since etcdctl refuses `--endpoints` alongside `ETCDCTL_ENDPOINTS`; its default 127.0.0.1:2379 is dialled over TLS once a client cert is set.
  etcdctl = pkgs.symlinkJoin {
    name = "etcd-tools";
    paths = cfg.tools;
    nativeBuildInputs = [ pkgs.makeWrapper ];
    postBuild = ''
      wrapProgram $out/bin/etcdctl \
        --set-default ETCDCTL_CACERT ${lib.escapeShellArg pki.ca.cert} \
        --set-default ETCDCTL_CERT ${lib.escapeShellArg pki.certs."etcd-client-cert".cert} \
        --set-default ETCDCTL_KEY ${lib.escapeShellArg pki.certs."etcd-client-cert".key}
    '';
  };
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
      # nixpkgs enables etcd only through the Kubernetes `master` role, which an etcd-only member lacks.
      enable = true;
      inherit (cfg) package;
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

    # `+` runs the hook as root, since the `etcd` user cannot read the client key.
    systemd.services.etcd = lib.mkIf autoJoinEnabled {
      environment = etcdctlCredentials;
      serviceConfig = {
        ExecStartPre = [ "+${lib.getExe autoJoinScript}" ];
        # Optional: a machine with data skips the join, and etcd ignores `initialCluster` once it has a WAL.
        EnvironmentFile = "-${initialClusterEnvFile}";
      };
    };

    systemd.services.etcd-promote = lib.mkIf autoJoinEnabled {
      description = "Promote this etcd learner to a voting member";
      after = [ "etcd.service" ];
      requires = [ "etcd.service" ];
      # A joining member's first start can time out fetching the snapshot, failing this job's dependency for good, so etcd's restart has to queue it again.
      wantedBy = [
        "multi-user.target"
        "etcd.service"
      ];
      environment = etcdctlCredentials;
      serviceConfig = {
        Type = "oneshot";
        # An argument rather than `environment`, which carries the clan var paths, so an evaluation-only check can read it.
        ExecStart = "${lib.getExe promoteScript} ${lib.escapeShellArg joinEndpoints}";
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
      # Wanted by etcd for the same reason as the promote unit.
      wantedBy = [
        "multi-user.target"
        "etcd.service"
      ];
      environment = etcdctlCredentials;
      serviceConfig = {
        Type = "oneshot";
        ExecStart = lib.escapeShellArgs (
          [
            (lib.getExe removeScript)
            joinEndpoints
          ]
          ++ cfg.removedMembers
        );
        # The other members may still be starting, or etcd may refuse the removal until enough are back for quorum.
        Restart = "on-failure";
        RestartSec = "30s";
      };
      unitConfig.StartLimitIntervalSec = 0;
    };

    networking.firewall.allowedTCPPorts = [
      2379
      2380
    ];

    environment.systemPackages = [ etcdctl ];
  };
}
