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

        options.clusterName = (import ../lib/options.nix { inherit lib; }).clusterName;
      };

    perInstance =
      {
        lib,
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
          imports = [ ./member.nix ];
          cluster.cairn.etcd = {
            inherit (settings) clusterName;
            advertiseAddress = settings.ip;
            nodes = lib.mapAttrsToList (name: m: {
              inherit name;
              ip = m.settings.ip;
            }) roles.member.machines;
          };
        };
      };
  };
}
