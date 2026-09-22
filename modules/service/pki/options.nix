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

  caChain = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    default = [ ];
    description = ''
      PEM certificates of the CA's issuers, up to and including a self-signed
      root, for a cluster CA that is an intermediate. Appended to the CA in
      `cluster.cairn.pki.ca.bundle`, which pods receive as `kube-root-ca.crt`.
      OpenSSL-based clients reject a bundle that does not end at a
      self-signed root. Never used to authenticate clients.
    '';
  };
}
