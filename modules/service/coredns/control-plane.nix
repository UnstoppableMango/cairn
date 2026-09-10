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
      description = ''
        Hostnames of the nodes CoreDNS may be scheduled onto, as
        `kubernetes.io/hostname` node affinity on the Deployment. These must
        be machines running a kubelet, which need not be the machines this
        role is assigned to. The manifest tolerates the control-plane and
        unschedulable taints, so control-plane nodes are valid entries.
      '';
    };

    serviceClusterIpRange = lib.mkOption {
      type = lib.types.str;
      default = "10.0.0.0/24";
      description = ''
        Service CIDR the cluster's apiserver serves, which `clusterIp` is
        derived from. Read here rather than off the local apiserver's own
        `services.kubernetes.apiserver.serviceClusterIpRange`, since the
        machine bootstrapping CoreDNS need not be running an apiserver.
        Keep it consistent with the apiserver's range.
      '';
    };

    clusterIp = lib.mkOption {
      type = lib.types.str;
      default =
        (lib.concatStringsSep "." (lib.take 3 (lib.splitString "." cfg.serviceClusterIpRange))) + ".254";
      defaultText = lib.literalMD "the `.254` address of `serviceClusterIpRange`";
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
          forward . 1.1.1.1 1.0.0.1
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
    services.kubernetes.addons.dns.enable = false;

    # Kubelet settings, so they only apply where a kubelet runs. A machine
    # that only bootstraps the manifests has no image to seed and no kubelet
    # to point at CoreDNS.
    services.kubernetes.kubelet = lib.mkIf config.services.kubernetes.kubelet.enable {
      seedDockerImages = [ cfg.image ];
      clusterDns = lib.mkDefault [ cfg.clusterIp ];
    };

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
