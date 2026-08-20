{
  config,
  lib,
  ...
}:
let
  cfg = config.cluster.cairn.apiserver;
  pki = config.cluster.cairn.pki;

  apiServerURL = "https://${cfg.vip}:6443";

  apiserverHosts = [
    cfg.vip
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
  options.cluster.cairn.apiserver = {
    nodes = lib.mkOption {
      type = lib.types.listOf (
        lib.types.submodule {
          options = {
            name = lib.mkOption { type = lib.types.str; };
            ip = lib.mkOption { type = lib.types.str; };
          };
        }
      );
      description = "All apiserver control-plane nodes with their names and IPs.";
    };

    vip = lib.mkOption {
      type = lib.types.str;
      description = "Keepalived virtual IP (VIP) for the cluster.";
    };

    apiServerURL = lib.mkOption {
      type = lib.types.str;
      default = apiServerURL;
      description = "External URL for the apiserver, fronted by the loadbalancer at the VIP.";
    };

    apiserverPort = lib.mkOption {
      type = lib.types.port;
      default = 6444;
      description = "Port the local apiserver binds to (loadbalancer fronts 6443 to this port).";
    };

    serviceClusterIP = lib.mkOption {
      type = lib.types.str;
      default = "10.0.0.1";
      description = "First IP of the service CIDR; included in apiserver SANs.";
    };

    clusterName = lib.mkOption {
      type = lib.types.str;
      description = "Cluster name; used in TLS certificate subject names.";
    };

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

    # -------------------------------------------------------------------------
    # Kubernetes control plane
    # -------------------------------------------------------------------------
    services.kubernetes = {
      roles = [ "master" ];
      masterAddress = cfg.vip;
      apiserverAddress = cfg.apiServerURL;
      easyCerts = false;
      caFile = pki.ca.cert;
      addonManager.enable = false;

      apiserver = {
        advertiseAddress = cfg.advertiseAddress;
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
      cfg.apiserverPort # kube-apiserver (internal; loadbalancer fronts 6443 externally)
      10257 # kube-controller-manager
      10259 # kube-scheduler
    ];

    # Preserved from the pre-split control-plane.nix; unrelated to any single
    # split-out component but historically control-plane-only.
    boot.kernelModules = [ "wireguard" ];
  };
}
