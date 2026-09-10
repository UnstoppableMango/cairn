{ cairnLib }:
{ clanLib, ... }:
{
  _class = "clan.service";
  manifest.name = "loadbalancer";
  manifest.readme = builtins.readFile ./README.md;
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
              inherit (settings)
                interface
                virtualRouterId
                keepalivedPriority
                healthCheck
                ;
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
