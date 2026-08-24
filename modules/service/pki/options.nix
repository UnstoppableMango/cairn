{ lib }:
{
  generatorPrefix = lib.mkOption {
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

  certValidityDays = lib.mkOption {
    type = lib.types.int;
    default = 3650;
    description = "Validity period for generated certificates in days.";
  };
}
