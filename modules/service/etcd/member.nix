{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.cluster.cairn.etcd;
  pki = config.cluster.cairn.pki;

  cairnOptions = import ../../../lib/options.nix { inherit lib; };

  localHosts = [
    cfg.advertiseAddress
    "127.0.0.1"
  ];

  etcdPeerEndpoints = map (n: "${n.name}=https://${n.ip}:2380") cfg.nodes;

  localNode = lib.findFirst (
    n: n.ip == cfg.advertiseAddress
  ) (throw "no etcd node matches advertiseAddress ${cfg.advertiseAddress}") cfg.nodes;
in
{
  options.cluster.cairn.etcd = {
    nodes = lib.mkOption {
      type = lib.types.listOf (
        lib.types.submodule {
          options = {
            name = lib.mkOption { type = lib.types.str; };
            ip = lib.mkOption { type = lib.types.str; };
          };
        }
      );
      description = "All etcd member nodes with their names and IPs.";
    };

    advertiseAddress = lib.mkOption {
      type = lib.types.str;
      description = "IP address this node advertises for etcd client/peer traffic.";
    };

    clusterName = cairnOptions.clusterName;

    initialClusterState = lib.mkOption {
      type = lib.types.enum [
        "new"
        "existing"
      ];
      default = "new";
      description = "etcd initial cluster state; set to \"existing\" when replacing a member or restoring into a live cluster.";
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
      # Used by apiserver (as an etcd client) and by etcdctl below. Declared
      # here rather than in the apiserver service since it's fundamentally an
      # "etcd client identity" and every etcd member already needs it for
      # local etcdctl tooling; apiserver machines pick it up via the same
      # shared (share = true) keypair.
      etcd-client-cert = {
        cn = "kube-apiserver-etcd-client";
        profile = "client";
        owner = "kubernetes";
      };
    };

    services.etcd = {
      name = localNode.name;
      listenClientUrls = [ "https://0.0.0.0:2379" ];
      listenPeerUrls = [ "https://0.0.0.0:2380" ];
      advertiseClientUrls = [ "https://${cfg.advertiseAddress}:2379" ];
      initialAdvertisePeerUrls = [ "https://${cfg.advertiseAddress}:2380" ];
      initialCluster = etcdPeerEndpoints;
      initialClusterState = cfg.initialClusterState;
      initialClusterToken = cfg.clusterName;
      clientCertAuth = true;
      peerClientCertAuth = true;
      trustedCaFile = pki.ca.cert;
      certFile = pki.certs."etcd-server-cert".cert;
      keyFile = pki.certs."etcd-server-cert".key;
      peerCertFile = pki.certs."etcd-peer-cert".cert;
      peerKeyFile = pki.certs."etcd-peer-cert".key;
      peerTrustedCaFile = pki.ca.cert;
    };

    networking.firewall.allowedTCPPorts = [
      2379 # etcd client
      2380 # etcd peer
    ];

    environment.systemPackages = [ pkgs.etcd ];

    environment.variables = {
      ETCDCTL_ENDPOINTS = "https://127.0.0.1:2379";
      ETCDCTL_CACERT = pki.ca.cert;
      ETCDCTL_CERT = pki.certs."etcd-client-cert".cert;
      ETCDCTL_KEY = pki.certs."etcd-client-cert".key;
    };
  };
}
