{ cairnLib }:
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
        options = (import ./options.nix { inherit lib; }) // {
          inherit (cairnLib.options) vip;
        };
      };

    perInstance =
      {
        settings,
        exports,
        ...
      }:
      {
        nixosModule = {
          imports = [ ./control-plane.nix ];
          cluster.cairn = {
            inherit (settings) vip;
            loadbalancer = {
              inherit (settings) interface virtualRouterId keepalivedPriority;
              # HAProxy just needs a dial string per backend; no need to split
              # "ip:port" apart.
              apiserverBackends = cairnLib.exports.endpointHosts clanLib {
                service = "apiserver";
                role = "control-plane";
              } exports;
            };
          };
        };
      };
  };
}
