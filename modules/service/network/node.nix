{ cairnLib }:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.cluster.cairn;
  pki = cfg.pki;

  flannelKubeconfig = pkgs.writeText "flannel.kubeconfig" (
    cairnLib.kubeconfig.mkKubeconfig {
      ca = pki.ca.cert;
      server = cfg.apiServerURL;
      clusterName = cfg.clusterName;
      userName = "flannel";
      contextName = "flannel@${cfg.clusterName}";
      certFile = pki.certs."flannel-cert".cert;
      keyFile = pki.certs."flannel-cert".key;
    }
  );
in
{
  imports = [ ../cluster.nix ];

  config = {
    cluster.cairn.pki.certs."flannel-cert" = {
      cn = "flannel";
      org = "system:masters";
      profile = "client";
      owner = "root";
    };

    cluster.cairn.pki.certs."kube-proxy-cert" = {
      cn = "system:kube-proxy";
      org = "system:kube-proxy";
      profile = "client";
      owner = "root";
    };

    services.kubernetes.flannel.enable = lib.mkForce false;
    services.flannel = {
      enable = true;
      storageBackend = "kubernetes";
      network = config.services.kubernetes.clusterCidr;
      kubeconfig = flannelKubeconfig;
      # clan sets meta.domain, making fqdnOrHostName return e.g. "node1.example.com",
      # but kubelet registers nodes with the short name.
      nodeName = config.networking.hostName;
    };
    services.kubernetes.kubelet.cni.config = lib.mkDefault [
      {
        name = "cni0";
        type = "flannel";
        cniVersion = "0.3.1";
        delegate = {
          isDefaultGateway = true;
          hairpinMode = true;
          bridge = "cni0";
        };
      }
    ];
    networking.dhcpcd.denyInterfaces = [
      "cni0*"
      "flannel*"
    ];

    networking.firewall.allowedUDPPorts = [
      8285 # flannel udp
      8472 # flannel VXLAN
    ];

    boot.kernelModules = [ "br_netfilter" ];

    boot.kernel.sysctl = {
      "net.bridge.bridge-nf-call-iptables" = lib.mkDefault 1;
      "net.bridge.bridge-nf-call-ip6tables" = lib.mkDefault 1;
      "net.ipv4.ip_forward" = lib.mkDefault 1;
    };
  };
}
