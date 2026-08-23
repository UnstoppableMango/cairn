{
  _class = "clan.service";
  manifest.name = "pki";
  manifest.readme = builtins.readFile ./README.md;

  roles.node = {
    description = "Machine that needs cluster PKI: the CA and any generated certificates.";

    interface =
      { lib, ... }:
      {
        options.generatorPrefix = lib.mkOption {
          type = lib.types.str;
          default = "cairn";
          description = ''
            Prefix used for clan var generator names (e.g. "<prefix>-ca",
            "<prefix>-<name>"). Override to match pre-existing generator names
            when migrating an existing cluster's PKI trust onto cairn, so
            already-provisioned CA/cert material is reused instead of
            regenerated.
          '';
        };

        options.certValidityDays = lib.mkOption {
          type = lib.types.int;
          default = 3650;
          description = "Validity period for generated certificates in days.";
        };
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
