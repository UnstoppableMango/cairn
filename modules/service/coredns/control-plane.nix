{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.cluster.cairn.coredns;

  ports = import ./ports.nix;
in
{
  options.cluster.cairn.coredns = {
    nodeNames = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      description = "Hostnames of control-plane nodes CoreDNS may be scheduled onto.";
    };

    clusterIp = lib.mkOption {
      type = lib.types.str;
      # Same convention Kubernetes tooling uses: the .254 address of the
      # service CIDR's first three octets.
      default =
        (lib.concatStringsSep "." (
          lib.take 3 (lib.splitString "." config.services.kubernetes.apiserver.serviceClusterIpRange)
        ))
        + ".254";
      description = "ClusterIP assigned to the kube-dns Service.";
    };

    clusterDomain = lib.mkOption {
      type = lib.types.str;
      default = "cluster.local";
      description = "Cluster domain CoreDNS serves.";
    };

    replicas = lib.mkOption {
      type = lib.types.int;
      default = 2;
      description = "Number of CoreDNS pod replicas.";
    };

    corefile = lib.mkOption {
      type = lib.types.str;
      default = ''
        .:${toString ports.dns} {
          errors
          health :${toString ports.health}
          kubernetes ${cfg.clusterDomain} in-addr.arpa ip6.arpa {
            pods insecure
            fallthrough in-addr.arpa ip6.arpa
          }
          forward . /etc/resolv.conf
          cache 30
          loop
          reload
          loadbalance
        }'';
      description = "CoreDNS Corefile contents.";
    };

    image = lib.mkOption {
      type = lib.types.package;
      default = pkgs.dockerTools.buildImage {
        name = "coredns";
        config.Entrypoint = [ "${pkgs.coredns}/bin/coredns" ];
      };
      description = "Docker image seeded for the CoreDNS container.";
    };
  };

  config = {
    # We author CoreDNS's manifests ourselves (./manifests.nix) instead of
    # harvesting nixpkgs' addonManager-computed ones, so nixpkgs' own DNS
    # addon module has nothing left to do here.
    services.kubernetes.addons.dns.enable = false;

    services.kubernetes.kubelet.seedDockerImages = [ cfg.image ];
    services.kubernetes.kubelet.clusterDns = lib.mkDefault [ cfg.clusterIp ];

    services.kubernetes.inoculant = {
      enable = true;
      manifests = import ./manifests.nix {
        inherit (cfg)
          clusterIp
          corefile
          replicas
          image
          nodeNames
          ;
      };
    };
  };
}
