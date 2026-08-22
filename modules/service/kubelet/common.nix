{
  config,
  lib,
  ...
}:
let
  cfg = config.cluster.cairn.kubelet;
  pki = config.cluster.cairn.pki;
in
{
  options.cluster.cairn.kubelet.advertiseAddress = lib.mkOption {
    type = lib.types.str;
    description = "IP address this node advertises for kubelet (included in the kubelet server certificate's SAN).";
  };

  config = {
    cluster.cairn.pki.certs = {
      kubelet-cert = {
        cn = "system:node:${config.networking.hostName}";
        org = "system:nodes";
        hosts = [ cfg.advertiseAddress ];
        share = false;
        profile = "peer";
        owner = "root";
      };
      kubelet-client-cert = {
        cn = "system:node:${config.networking.hostName}";
        org = "system:nodes";
        share = false;
        profile = "client";
        owner = "root";
      };
    };

    services.kubernetes.kubelet = {
      # clan sets meta.domain, which causes networking.fqdnOrHostName to return
      # e.g. "node1.example.com". The NixOS kubelet default uses fqdnOrHostName,
      # but cert CNs are generated from the short hostname ("system:node:node1").
      # Node Authorizer rejects: cert subject "node1" cannot read node "node1.example.com".
      hostname = config.networking.hostName;
      clientCaFile = pki.ca.cert;
      tlsCertFile = pki.certs."kubelet-cert".cert;
      tlsKeyFile = pki.certs."kubelet-cert".key;
      kubeconfig = {
        certFile = pki.certs."kubelet-client-cert".cert;
        keyFile = pki.certs."kubelet-client-cert".key;
      };
    };

    services.kubernetes.proxy.kubeconfig = {
      certFile = pki.certs."kube-proxy-cert".cert;
      keyFile = pki.certs."kube-proxy-cert".key;
    };

    networking.firewall.allowedTCPPorts = [
      10250 # kubelet API
    ];
  };
}
