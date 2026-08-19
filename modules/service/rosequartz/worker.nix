{
  config,
  lib,
  ...
}:
let
  cfg = config.cluster.rosequartz;
in
{
  imports = [
    ./kubeconfig.nix
    ./network.nix
    ./pki.nix
  ];

  options.cluster.rosequartz = {
    vip = lib.mkOption {
      type = lib.types.str;
      description = "Keepalived virtual IP (VIP) for the cluster.";
    };

    clusterName = lib.mkOption {
      type = lib.types.str;
      description = "Cluster name; used in TLS certificate subject names.";
    };

    advertiseAddress = lib.mkOption {
      type = lib.types.str;
      description = "IP address this worker node advertises (included in kubelet server cert SAN).";
    };
  };

  config = {
    cluster.rosequartz.pki.certs = {
      worker-kubelet-cert = {
        cn = "system:node:${config.networking.hostName}";
        org = "system:nodes";
        hosts = [ cfg.advertiseAddress ];
        share = false;
        profile = "peer";
        owner = "root";
      };
      worker-kubelet-client-cert = {
        cn = "system:node:${config.networking.hostName}";
        org = "system:nodes";
        share = false;
        profile = "client";
        owner = "root";
      };
    };

    # -------------------------------------------------------------------------
    # Kubernetes worker
    # -------------------------------------------------------------------------
    services.kubernetes = {
      roles = [ "node" ];
      masterAddress = cfg.vip;
      apiserverAddress = "https://${cfg.vip}:6443";
      easyCerts = false;
      caFile = cfg.pki.ca.cert;

      kubelet = {
        # See control-plane.nix kubelet.hostname comment — same FQDN/cert CN mismatch applies.
        hostname = config.networking.hostName;
        clientCaFile = cfg.pki.ca.cert;
        tlsCertFile = cfg.pki.certs."worker-kubelet-cert".cert;
        tlsKeyFile = cfg.pki.certs."worker-kubelet-cert".key;
        kubeconfig = {
          certFile = cfg.pki.certs."worker-kubelet-client-cert".cert;
          keyFile = cfg.pki.certs."worker-kubelet-client-cert".key;
        };
      };
    };

    # -------------------------------------------------------------------------
    # Network
    # -------------------------------------------------------------------------
    networking.firewall = {
      allowedTCPPorts = [
        10250 # kubelet API
      ];
    };

    boot.kernelModules = [
      "br_netfilter"
    ];

    boot.kernel.sysctl = {
      "net.bridge.bridge-nf-call-iptables" = lib.mkDefault 1;
      "net.bridge.bridge-nf-call-ip6tables" = lib.mkDefault 1;
      "net.ipv4.ip_forward" = lib.mkDefault 1;
    };
  };
}
