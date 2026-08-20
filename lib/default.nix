{ lib }:
{
  options = import ./options.nix { inherit lib; };
  kubeconfig = import ./kubeconfig.nix;
}
