{ cairnLib }:
{
  config,
  lib,
  ...
}:
let
  cfg = config.cluster.cairn.apiserver;
  pki = config.cluster.cairn.pki;

  apiserverHosts = [
    config.cluster.cairn.vip
  ]
  ++ (map (n: n.ip) cfg.nodes)
  ++ [
    cfg.serviceClusterIP
    "127.0.0.1"
    "kubernetes"
    "kubernetes.default"
    "kubernetes.default.svc"
    "kubernetes.default.svc.cluster.local"
    "localhost"
  ];
in
{
  imports = [ ../cluster.nix ];

  options.cluster.cairn.apiserver = (import ./options.nix { inherit lib; }) // {
    nodes = cairnLib.options.mkNodes "All apiserver control-plane nodes with their names and IPs.";

    advertiseAddress = lib.mkOption {
      type = lib.types.str;
      description = "IP address this node advertises for the apiserver.";
    };

    etcdEndpoints = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      description = "etcd client endpoints (https://<ip>:2379), from the etcd service's exports.";
    };
  };

  config = {
    cluster.cairn.pki.certs = {
      sa = {
        cn = "service-accounts";
        profile = "client";
        owner = "kubernetes";
      };
      apiserver-cert = {
        cn = "kube-apiserver";
        hosts = apiserverHosts;
        profile = "server";
        owner = "kubernetes";
      };
      apiserver-kubelet-client-cert = {
        cn = "kube-apiserver-kubelet-client";
        org = "system:masters";
        profile = "client";
        owner = "kubernetes";
      };
      controller-manager-cert = {
        cn = "system:kube-controller-manager";
        org = "system:kube-controller-manager";
        profile = "client";
        owner = "kubernetes";
      };
      scheduler-cert = {
        cn = "system:kube-scheduler";
        org = "system:kube-scheduler";
        profile = "client";
        owner = "kubernetes";
      };
    };

    services.kubernetes = {
      roles = [ "master" ];
      masterAddress = config.cluster.cairn.vip;
      apiserverAddress = config.cluster.cairn.apiServerURL;
      easyCerts = false;
      caFile = pki.ca.cert;
      addonManager.enable = false;

      apiserver = {
        advertiseAddress = cfg.advertiseAddress;
        preferredAddressTypes = "InternalIP";
        securePort = cfg.apiserverPort;
        clientCaFile = pki.ca.cert;
        tlsCertFile = pki.certs."apiserver-cert".cert;
        tlsKeyFile = pki.certs."apiserver-cert".key;
        serviceAccountKeyFile = pki.certs."sa".cert;
        serviceAccountSigningKeyFile = pki.certs."sa".key;
        kubeletClientCertFile = pki.certs."apiserver-kubelet-client-cert".cert;
        kubeletClientKeyFile = pki.certs."apiserver-kubelet-client-cert".key;
        etcd = {
          servers = cfg.etcdEndpoints;
          caFile = pki.ca.cert;
          certFile = pki.certs."etcd-client-cert".cert;
          keyFile = pki.certs."etcd-client-cert".key;
        };
      };

      controllerManager = {
        serviceAccountKeyFile = pki.certs."sa".key;
        kubeconfig = {
          certFile = pki.certs."controller-manager-cert".cert;
          keyFile = pki.certs."controller-manager-cert".key;
        };
      };

      scheduler.kubeconfig = {
        certFile = pki.certs."scheduler-cert".cert;
        keyFile = pki.certs."scheduler-cert".key;
      };
    };

    networking.firewall.allowedTCPPorts = [
      cfg.apiserverPort
      10257
      10259
    ];

    boot.kernelModules = [ "wireguard" ];
  };
}
