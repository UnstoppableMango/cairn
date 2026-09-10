{ lib }:
{
  options = import ./options.nix { inherit lib; };
  kubeconfig = import ./kubeconfig.nix;
  inventory = import ./inventory.nix { inherit lib; };
  exports = import ./exports.nix { inherit lib; };
}
