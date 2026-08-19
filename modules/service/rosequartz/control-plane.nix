{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.cluster.rosequartz;

  nodeIps = map (n: n.ip) cfg.nodes;
  apiserverHosts = [
    cfg.vip
  ]
  ++ nodeIps
  ++ [
    cfg.serviceClusterIP
    "127.0.0.1"
    "kubernetes"
    "kubernetes.default"
    "kubernetes.default.svc"
    "kubernetes.default.svc.cluster.local"
    "localhost"
  ];
  localHosts = [
    cfg.advertiseAddress
    "127.0.0.1"
  ];

  etcdClientEndpoints = map (n: "https://${n.ip}:2379") cfg.nodes;
  etcdPeerEndpoints = map (n: "${n.name}=https://${n.ip}:2380") cfg.nodes;

  localNode = lib.findFirst (
    n: n.ip == cfg.advertiseAddress
  ) (throw "no rosequartz node matches advertiseAddress ${cfg.advertiseAddress}") cfg.nodes;
in
{
  imports = [
    ./kubeconfig.nix
    ./network.nix
    ./pki.nix
    ./flux.nix
  ];

  options.cluster.rosequartz = {
    nodes = lib.mkOption {
      type = lib.types.listOf (
        lib.types.submodule {
          options = {
            name = lib.mkOption { type = lib.types.str; };
            ip = lib.mkOption { type = lib.types.str; };
          };
        }
      );
      description = "All control plane nodes with their names and IPs.";
    };

    vip = lib.mkOption {
      type = lib.types.str;
      description = "Keepalived virtual IP (VIP) for the cluster.";
    };

    apiserverPort = lib.mkOption {
      type = lib.types.port;
      default = 6444;
      description = "Port the local apiserver binds to (HAProxy fronts 6443 to this port).";
    };

    interface = lib.mkOption {
      type = lib.types.str;
      description = "Network interface for keepalived VRRP.";
    };

    virtualRouterId = lib.mkOption {
      type = lib.types.int;
      default = 50;
      description = "Keepalived VRRP virtual router ID (1-255, unique per subnet).";
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
      description = "IP address this node advertises for the apiserver and etcd.";
    };

    keepalivedPriority = lib.mkOption {
      type = lib.types.int;
      default = 100;
      description = "VRRP priority — highest wins the VIP.";
    };

    etcd.advertiseClientUrls = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      description = "etcd client URLs advertised to the cluster (https://<node-ip>:2379).";
    };

    etcd.initialAdvertisePeerUrls = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      description = "etcd peer URLs advertised during bootstrap (https://<node-ip>:2380).";
    };

    etcd.initialCluster = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      description = "etcd initial cluster peer URLs; defaults to all nodes, override during member replacement.";
    };

    etcd.initialClusterState = lib.mkOption {
      type = lib.types.enum [
        "new"
        "existing"
      ];
      default = "new";
      description = "etcd initial cluster state; set to \"existing\" when replacing a member or restoring into a live cluster.";
    };
  };

  config = {
    cluster.rosequartz = {
      etcd.initialCluster = lib.mkDefault etcdPeerEndpoints;

      pki.certs = {
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
        etcd-client-cert = {
          cn = "kube-apiserver-etcd-client";
          profile = "client";
          owner = "kubernetes";
        };
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
        kubelet-cert = {
          cn = "system:node:${localNode.name}";
          org = "system:nodes";
          hosts = [ cfg.advertiseAddress ];
          share = false;
          profile = "peer";
          owner = "root";
        };
        kubelet-client-cert = {
          cn = "system:node:${localNode.name}";
          org = "system:nodes";
          share = false;
          profile = "client";
          owner = "root";
        };
      };
    };

    # -------------------------------------------------------------------------
    # Kubernetes control plane
    # -------------------------------------------------------------------------
    services.kubernetes = {
      roles = [ "master" ];
      masterAddress = cfg.vip;
      apiserverAddress = "https://${cfg.vip}:6443";
      easyCerts = false;
      caFile = cfg.pki.ca.cert;
      addonManager.enable = false;

      apiserver = {
        advertiseAddress = cfg.advertiseAddress;
        securePort = cfg.apiserverPort;
        clientCaFile = cfg.pki.ca.cert;
        tlsCertFile = cfg.pki.certs."apiserver-cert".cert;
        tlsKeyFile = cfg.pki.certs."apiserver-cert".key;
        serviceAccountKeyFile = cfg.pki.certs."sa".cert;
        serviceAccountSigningKeyFile = cfg.pki.certs."sa".key;
        kubeletClientCertFile = cfg.pki.certs."apiserver-kubelet-client-cert".cert;
        kubeletClientKeyFile = cfg.pki.certs."apiserver-kubelet-client-cert".key;
        etcd = {
          servers = etcdClientEndpoints;
          caFile = cfg.pki.ca.cert;
          certFile = cfg.pki.certs."etcd-client-cert".cert;
          keyFile = cfg.pki.certs."etcd-client-cert".key;
        };
      };

      controllerManager = {
        serviceAccountKeyFile = cfg.pki.certs."sa".key;
        kubeconfig = {
          certFile = cfg.pki.certs."controller-manager-cert".cert;
          keyFile = cfg.pki.certs."controller-manager-cert".key;
        };
      };

      scheduler.kubeconfig = {
        certFile = cfg.pki.certs."scheduler-cert".cert;
        keyFile = cfg.pki.certs."scheduler-cert".key;
      };

      kubelet = {
        # clan sets meta.domain = "thecluster.io", which causes networking.fqdnOrHostName
        # to return "pik8s4.thecluster.io". The NixOS kubelet default uses fqdnOrHostName,
        # but cert CNs are generated from the short inventory name ("system:node:pik8s4").
        # Node Authorizer rejects: cert subject "pik8s4" cannot read node "pik8s4.thecluster.io".
        hostname = config.networking.hostName;
        clientCaFile = cfg.pki.ca.cert;
        tlsCertFile = cfg.pki.certs."kubelet-cert".cert;
        tlsKeyFile = cfg.pki.certs."kubelet-cert".key;
        kubeconfig = {
          certFile = cfg.pki.certs."kubelet-client-cert".cert;
          keyFile = cfg.pki.certs."kubelet-client-cert".key;
        };
      };
    };

    # -------------------------------------------------------------------------
    # etcd cluster
    # -------------------------------------------------------------------------
    services.etcd = {
      name = localNode.name;
      listenClientUrls = [ "https://0.0.0.0:2379" ];
      listenPeerUrls = [ "https://0.0.0.0:2380" ];
      advertiseClientUrls = cfg.etcd.advertiseClientUrls;
      initialAdvertisePeerUrls = cfg.etcd.initialAdvertisePeerUrls;
      initialCluster = cfg.etcd.initialCluster;
      initialClusterState = cfg.etcd.initialClusterState;
      initialClusterToken = cfg.clusterName;
      clientCertAuth = true;
      peerClientCertAuth = true;
      trustedCaFile = cfg.pki.ca.cert;
      certFile = cfg.pki.certs."etcd-server-cert".cert;
      keyFile = cfg.pki.certs."etcd-server-cert".key;
      peerCertFile = cfg.pki.certs."etcd-peer-cert".cert;
      peerKeyFile = cfg.pki.certs."etcd-peer-cert".key;
      peerTrustedCaFile = cfg.pki.ca.cert;
    };

    # -------------------------------------------------------------------------
    # keepalived — floating VIP
    # -------------------------------------------------------------------------
    services.keepalived = {
      enable = true;
      openFirewall = true;
      vrrpInstances.VI_K8S = {
        interface = cfg.interface;
        state = "BACKUP";
        virtualRouterId = cfg.virtualRouterId;
        priority = cfg.keepalivedPriority;
        virtualIps = [ { addr = "${cfg.vip}/24"; } ];
      };
    };

    # -------------------------------------------------------------------------
    # HAProxy — LB from VIP:6443 → apiserver:6444 on all nodes
    # -------------------------------------------------------------------------
    services.haproxy = {
      enable = true;
      config = ''
        global
          log /dev/log local0
          maxconn 4000

        defaults
          log global
          mode tcp
          timeout connect 5s
          timeout client 1h
          timeout server 1h
          timeout tunnel 1h

        frontend k8s-api
          bind *:6443
          default_backend k8s-api-backend

        backend k8s-api-backend
          balance roundrobin
          option tcp-check
          ${lib.concatMapStringsSep "\n          " (
            n: "server ${n.name} ${n.ip}:${toString cfg.apiserverPort} check"
          ) cfg.nodes}
      '';
    };

    # -------------------------------------------------------------------------
    # Network
    # -------------------------------------------------------------------------
    networking.firewall = {
      allowedTCPPorts = [
        6443 # HAProxy / kube-apiserver (external via VIP)
        cfg.apiserverPort # kube-apiserver (internal)
        2379 # etcd client
        2380 # etcd peer
        10250 # kubelet API
        10257 # kube-controller-manager
        10259 # kube-scheduler
      ];
    };

    boot.kernelModules = [
      "br_netfilter"
      "wireguard"
    ];

    boot.kernel.sysctl = {
      "net.bridge.bridge-nf-call-iptables" = lib.mkDefault 1;
      "net.bridge.bridge-nf-call-ip6tables" = lib.mkDefault 1;
      "net.ipv4.ip_forward" = lib.mkDefault 1;
    };

    environment.systemPackages = [ pkgs.etcd ];

    environment.variables = {
      ETCDCTL_ENDPOINTS = "https://127.0.0.1:2379";
      ETCDCTL_CACERT = cfg.pki.ca.cert;
      ETCDCTL_CERT = cfg.pki.certs."etcd-client-cert".cert;
      ETCDCTL_KEY = cfg.pki.certs."etcd-client-cert".key;
    };
  };
}
