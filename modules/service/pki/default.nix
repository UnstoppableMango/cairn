{
  _class = "clan.service";
  manifest.name = "pki";
  manifest.readme = builtins.readFile ./README.md;

  roles.node = {
    description = "Machine that needs cluster PKI: the CA and any generated certificates.";
    perInstance.nixosModule = ./node.nix;
  };
}
