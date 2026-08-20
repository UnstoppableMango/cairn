{
  _class = "clan.service";
  manifest.name = "cairn";
  manifest.readme = builtins.readFile ./README.md;

  roles.control-plane = {
    description = "Control plane node";

    interface =
      { lib, ... }:
      {
        options.ip = lib.mkOption {
          type = lib.types.str;
          description = "IP address of this control plane node.";
        };

        options.vip = lib.mkOption {
          type = lib.types.str;
          description = "Keepalived virtual IP (VIP) for the cluster.";
        };

        options.clusterName = lib.mkOption {
          type = lib.types.str;
          description = "Cluster name; used in TLS certificate subject names.";
        };
      };

    perInstance =
      {
        lib,
        settings,
        roles,
        ...
      }:
      {
        nixosModule = {
          imports = [ ./control-plane.nix ];
          cluster.cairn = {
            inherit (settings) vip clusterName;
            nodes = lib.mapAttrsToList (name: m: {
              inherit name;
              ip = m.settings.ip;
            }) roles.control-plane.machines;
          };
        };
      };
  };

  roles.worker = {
    description = "Worker node";

    interface =
      { lib, ... }:
      {
        options.ip = lib.mkOption {
          type = lib.types.str;
          description = "IP address of this worker node.";
        };
      };

    perInstance =
      {
        lib,
        settings,
        roles,
        ...
      }:
      let
        controlPlane =
          (lib.throwIfNot (roles.control-plane.machines != { })
            "cairn worker role requires at least one control-plane machine in the same instance"
            (lib.head (lib.attrValues roles.control-plane.machines))
          ).settings;
      in
      {
        nixosModule = {
          imports = [ ./worker.nix ];
          cluster.cairn = {
            inherit (controlPlane) vip clusterName;
            advertiseAddress = settings.ip;
          };
        };
      };
  };
}
