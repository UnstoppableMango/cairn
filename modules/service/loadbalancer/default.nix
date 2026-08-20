{ clanLib, ... }:
{
  _class = "clan.service";
  manifest.name = "loadbalancer";
  manifest.readme = builtins.readFile ./README.md;
  # See etcd/default.nix for why "endpoints" is used here.
  manifest.exports.inputs = [ "endpoints" ];

  roles.control-plane = {
    description = "Fronts the apiserver cluster with a keepalived VIP and HAProxy.";

    interface =
      { lib, ... }:
      {
        options.vip = lib.mkOption {
          type = lib.types.str;
          description = "Keepalived virtual IP (VIP) for the cluster.";
        };

        options.interface = lib.mkOption {
          type = lib.types.str;
          description = "Network interface for keepalived VRRP.";
        };

        options.virtualRouterId = lib.mkOption {
          type = lib.types.int;
          default = 50;
          description = "Keepalived VRRP virtual router ID (1-255, unique per subnet).";
        };

        options.keepalivedPriority = lib.mkOption {
          type = lib.types.int;
          default = 100;
          description = "VRRP priority — highest wins the VIP.";
        };
      };

    perInstance =
      {
        lib,
        settings,
        exports,
        ...
      }:
      let
        apiserverHosts = lib.concatMap (e: e.endpoints.hosts) (
          lib.attrValues (
            clanLib.selectExports (
              scope: scope.serviceName == "apiserver" && scope.roleName == "control-plane"
            ) exports
          )
        );
        apiserverNodes = map (
          host:
          let
            parts = lib.splitString ":" host;
          in
          {
            ip = lib.head parts;
            port = lib.toIntBase10 (lib.last parts);
          }
        ) apiserverHosts;
      in
      {
        nixosModule = {
          imports = [ ./control-plane.nix ];
          cluster.cairn.loadbalancer = {
            inherit (settings)
              vip
              interface
              virtualRouterId
              keepalivedPriority
              ;
            inherit apiserverNodes;
          };
        };
      };
  };
}
