{ kubepkgs }:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.cluster.cairn.metricsServer;

  release = import ../releases.nix { inherit kubepkgs; };

  v = config.cluster.cairn.kubernetesVersion;

  # nixpkgs ships no metrics-server, so the package always comes from
  # kubepkgs: the cluster's pinned minor where there is one, and kubepkgs'
  # newest minor otherwise, which is the closest thing to "follow the
  # toolchain" available when nothing is pinned.
  sigs =
    (release {
      inherit lib pkgs;
      version = if v != null then v else "latest";
    }).sigs;
in
{
  imports = [ ../version.nix ];

  options.cluster.cairn.metricsServer = {
    nodeNames = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      description = ''
        Hostnames of the nodes metrics-server may be scheduled onto, as
        `kubernetes.io/hostname` node affinity on the Deployment. These must
        be machines running a kubelet that also have the pki service
        assigned, since the pod mounts the cluster CA off the node to verify
        kubelet serving certs.
      '';
    };

    package = lib.mkOption {
      type = lib.types.package;
      default = sigs.metrics-server;
      defaultText = lib.literalMD "metrics-server from the cluster's pinned kubepkgs minor";
      description = "metrics-server build the container image is made from.";
    };

    image = lib.mkOption {
      type = lib.types.package;
      default = pkgs.dockerTools.buildImage {
        name = "metrics-server";
        tag = cfg.package.version;
        config = {
          Entrypoint = [ "${cfg.package}/bin/metrics-server" ];
          User = "1000";
        };
      };
      defaultText = lib.literalMD "an image wrapping `package`";
      description = "Docker image seeded for the metrics-server container.";
    };

    replicas = lib.mkOption {
      type = lib.types.int;
      default = 1;
      description = ''
        Number of metrics-server pod replicas. More than one needs
        `--enable-aggregator-routing` on the apiserver, which cairn sets, and
        each replica scrapes every kubelet independently.
      '';
    };

    metricResolution = lib.mkOption {
      type = lib.types.str;
      default = "15s";
      description = "How often metrics-server scrapes kubelets (`--metric-resolution`). Must stay below the 60s window the Metrics API serves.";
    };

    extraArgs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "--kubelet-insecure-tls" ];
      description = "Extra arguments appended to the metrics-server container's command line.";
    };
  };

  config = {
    # Kubelet settings, so they only apply where a kubelet runs: a machine
    # that only bootstraps the manifests has no image to seed.
    services.kubernetes.kubelet = lib.mkIf config.services.kubernetes.kubelet.enable {
      seedDockerImages = [ cfg.image ];
    };

    services.kubernetes.inoculant = {
      enable = true;

      # inoculant scopes its own RBAC to the kinds it finds in `manifests`,
      # and RBAC keys the "bind" check on the referenced role's resource
      # rather than on rolebindings. The auth-reader RoleBinding here
      # references the apiserver's own
      # `extension-apiserver-authentication-reader` Role, and this addon
      # ships no Role of its own, so nothing in the manifest set grants
      # `bind` on roles and the binding is refused.
      additionalAllowedGVKs = [
        {
          group = "rbac.authorization.k8s.io";
          ver = "v1";
          kind = "Role";
        }
      ];
      manifests = import ./manifests.nix {
        inherit (cfg)
          image
          nodeNames
          replicas
          metricResolution
          extraArgs
          ;
        kubeletCaFile = config.cluster.cairn.pki.ca.cert;
      };
    };
  };
}
