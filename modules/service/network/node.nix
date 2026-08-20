{
  config,
  lib,
  pkgs,
  inputs,
  ...
}:
let
  cfg = config.cluster.cairn.network;
  pki = config.cluster.cairn.pki;
  kubeconfigLib = inputs.self.lib.kubeconfig;

  apiServerURL = "https://${cfg.vip}:6443";

  flannelKubeconfig = pkgs.writeText "flannel.kubeconfig" (
    kubeconfigLib.mkKubeconfig {
      ca = pki.ca.cert;
      server = apiServerURL;
      clusterName = cfg.clusterName;
      userName = "flannel";
      contextName = "flannel@${cfg.clusterName}";
      certFile = pki.certs."flannel-cert".cert;
      keyFile = pki.certs."flannel-cert".key;
    }
  );
in
{
  options.cluster.cairn.network = {
    vip = inputs.self.lib.options.vip;
    clusterName = inputs.self.lib.options.clusterName;
  };

  config = {
    # nixpkgs' flannel-0.28.6 fixed-output derivation has a stale hash for the
    # GitHub archive tarball (upstream archive content drifted). Pin to the
    # actually-observed hash until nixpkgs picks up a fix.
    nixpkgs.overlays = [
      (_final: prev: {
        flannel = prev.flannel.overrideAttrs (old: {
          src = old.src.overrideAttrs (_: {
            outputHash = "sha256-sqpsUAKBza96AMQMUCG94KOht5ExnHRLR7eGna3m3Xg=";
          });
        });
      })
    ];

    cluster.cairn.pki.certs."flannel-cert" = {
      cn = "flannel";
      org = "system:masters";
      profile = "client";
      owner = "root";
    };

    services.kubernetes.flannel.enable = lib.mkForce false;
    services.flannel = {
      enable = true;
      storageBackend = "kubernetes";
      network = config.services.kubernetes.clusterCidr;
      kubeconfig = flannelKubeconfig;
      # clan sets meta.domain = "thecluster.io", making fqdnOrHostName return
      # "pik8s4.thecluster.io", but kubelet registers nodes with the short name.
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
