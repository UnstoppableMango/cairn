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
