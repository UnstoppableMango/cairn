{ cairnLib }:
{
  _class = "clan.service";
  manifest.name = "etcd";
  manifest.readme = builtins.readFile ./README.md;
  # clan's exports mechanism only allows a fixed set of typed interfaces
  # (endpoints, peer, networking, dataMesher, generators, auth); "endpoints"
  # (a bare listOf str under `.hosts`) is the closest fit for "a URL per
  # machine", so client URLs are packed as plain strings there.
  manifest.exports.out = [ "endpoints" ];

  roles.member = {
    description = "etcd cluster member";

    interface =
      { lib, ... }:
      {
        options.ip = lib.mkOption {
          type = lib.types.str;
          description = "IP address of this etcd member.";
        };

        options.clusterName = cairnLib.options.clusterName;
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
          imports = [ (import ./member.nix { inherit cairnLib; }) ];
          cluster.cairn = {
            inherit (settings) clusterName;
            etcd = {
              advertiseAddress = settings.ip;
              nodes = cairnLib.inventory.nodesOf roles.member.machines;
            };
          };
        };
      };
  };
}
