{ cairnLib }:
{ clanLib, ... }:
{
  _class = "clan.service";
  manifest.name = "apiserver";
  manifest.readme = builtins.readFile ./README.md;
  manifest.exports.inputs = [ "endpoints" ];
  manifest.exports.out = [ "endpoints" ];

  roles.control-plane = {
    description = "Runs kube-apiserver, kube-controller-manager, and kube-scheduler.";

    interface =
      { lib, ... }:
      {
        options = (import ./options.nix { inherit lib; }) // {
          ip = lib.mkOption {
            type = lib.types.str;
            description = "IP address this apiserver node advertises.";
          };

          inherit (cairnLib.options) vip clusterName;
        };
      };

    perInstance =
      {
        settings,
        roles,
        exports,
        mkExports,
        ...
      }:
      {
        exports = mkExports {
          endpoints.hosts = [ "${settings.ip}:${toString settings.apiserverPort}" ];
        };

        nixosModule = {
          imports = [ (import ./control-plane.nix { inherit cairnLib; }) ];
          cluster.cairn = {
            inherit (settings) vip clusterName;
            apiserver = {
              inherit (settings) apiserverPort serviceClusterIP;
              advertiseAddress = settings.ip;
              nodes = cairnLib.inventory.nodesOf roles.control-plane.machines;
              etcdEndpoints = cairnLib.exports.endpointHosts clanLib {
                service = "etcd";
                role = "member";
              } exports;
            };
          };
        };
      };
  };
}
