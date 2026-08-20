{
  config,
  lib,
  ...
}:
let
  cfg = config.cluster.cairn.kubelet;
  pki = config.cluster.cairn.pki;

  apiServerURL = "https://${cfg.vip}:6443";
in
{
  options.cluster.cairn.kubelet = {
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
    cluster.cairn.pki.certs = {
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

    services.kubernetes = {
      roles = [ "node" ];
      masterAddress = cfg.vip;
      apiserverAddress = apiServerURL;
      easyCerts = false;
      caFile = pki.ca.cert;

      kubelet = {
        # See control-plane.nix's kubelet.hostname comment — same FQDN/cert CN mismatch applies.
        hostname = config.networking.hostName;
        clientCaFile = pki.ca.cert;
        tlsCertFile = pki.certs."worker-kubelet-cert".cert;
        tlsKeyFile = pki.certs."worker-kubelet-cert".key;
        kubeconfig = {
          certFile = pki.certs."worker-kubelet-client-cert".cert;
          keyFile = pki.certs."worker-kubelet-client-cert".key;
        };
      };
    };

    networking.firewall.allowedTCPPorts = [
      10250 # kubelet API
    ];
  };
}
