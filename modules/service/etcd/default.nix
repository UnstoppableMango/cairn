{ cairnLib, kubepkgs }:
{ lib, ... }:
let
  versionModule = lib.modules.importApply ./version.nix { inherit kubepkgs; };
in
{
  _class = "clan.service";
  manifest.name = "etcd";
  manifest.readme = builtins.readFile ./README.md;
  manifest.exports.out = [ "endpoints" ];

  roles.member = {
    description = "etcd cluster member";

    interface =
      { lib, ... }:
      {
        options = {
          ip = lib.mkOption {
            type = lib.types.str;
            description = "IP address of this etcd member.";
          };

          inherit (cairnLib.options) clusterName kubernetesVersion;
        };
      };

    perInstance =
      {
        settings,
        roles,
        mkExports,
        ...
      }:
      {
        exports = mkExports {
          endpoints.hosts = [ "https://${settings.ip}:2379" ];
        };

        nixosModule = {
          imports = [
            (import ./member.nix { inherit cairnLib; })
            versionModule
          ];
          cluster.cairn = {
            inherit (settings) clusterName kubernetesVersion;
            etcd = {
              advertiseAddress = settings.ip;
              nodes = cairnLib.inventory.nodesOf roles.member.machines;
            };
          };
        };
      };
  };
}
