{
  _class = "clan.service";
  manifest.name = "pki";
  manifest.readme = builtins.readFile ./README.md;

  roles.node = {
    description = "Machine that needs cluster PKI: the CA and any generated certificates.";

    interface =
      { lib, ... }:
      {
        options = import ./options.nix { inherit lib; };
      };

    perInstance =
      { settings, ... }:
      {
        nixosModule = {
          imports = [ ./node.nix ];
          cluster.cairn.pki = {
            inherit (settings) generatorPrefix certValidityDays;
          };
        };
      };
  };
}
