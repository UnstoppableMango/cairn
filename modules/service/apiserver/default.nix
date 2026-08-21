{ cairnLib }:
{ clanLib, ... }:
{
  _class = "clan.service";
  manifest.name = "apiserver";
  manifest.readme = builtins.readFile ./README.md;
  # See etcd/default.nix for why "endpoints" is used for both directions.
  manifest.exports.inputs = [ "endpoints" ];
  manifest.exports.out = [ "endpoints" ];

  roles.control-plane = {
    description = "Runs kube-apiserver, kube-controller-manager, and kube-scheduler.";

    interface =
      { lib, ... }:
      {
        options.ip = lib.mkOption {
          type = lib.types.str;
          description = "IP address this apiserver node advertises.";
        };

        options.vip = cairnLib.options.vip;
        options.clusterName = cairnLib.options.clusterName;

        options.apiserverPort = lib.mkOption {
          type = lib.types.port;
          default = 6444;
          description = "Port the local apiserver binds to (fronted externally by loadbalancer at 6443).";
        };

        options.serviceClusterIP = lib.mkOption {
          type = lib.types.str;
          default = "10.0.0.1";
          description = "First IP of the service CIDR; included in apiserver SANs.";
        };
      };

    perInstance =
      {
        lib,
        settings,
        roles,
        exports,
        mkExports,
        ...
      }:
      let
        etcdEndpoints = lib.concatMap (e: e.endpoints.hosts) (
          lib.attrValues (
            clanLib.selectExports (scope: scope.serviceName == "etcd" && scope.roleName == "member") exports
          )
        );
      in
      {
        # loadbalancer consumes these as opaque HAProxy dial targets ("ip:port").
        exports = mkExports {
          endpoints.hosts = [ "${settings.ip}:${toString settings.apiserverPort}" ];
        };

        nixosModule = {
          imports = [ (import ./control-plane.nix { inherit cairnLib; }) ];
          cluster.cairn.apiserver = {
            inherit (settings)
              vip
              clusterName
              apiserverPort
              serviceClusterIP
              ;
            advertiseAddress = settings.ip;
            inherit etcdEndpoints;
            nodes = lib.mapAttrsToList (name: m: {
              inherit name;
              ip = m.settings.ip;
            }) roles.control-plane.machines;
          };
        };
      };
  };
}
