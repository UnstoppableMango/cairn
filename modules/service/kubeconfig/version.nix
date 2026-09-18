# Pins the kubectl on the machine's PATH to the cluster's Kubernetes minor.
#
# Kubernetes supports a one-minor kubectl skew in either direction. A cluster
# held at an older minor while nixpkgs moves on can drift further than that,
# and the mismatch surfaces as an API error rather than a version banner.
{ kubepkgs }:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  release = import ../releases.nix { inherit kubepkgs; };
  v = config.cluster.cairn.kubernetesVersion;
in
{
  imports = [ ../version.nix ];

  config = lib.mkIf (v != null) {
    # mkDefault so a consumer overriding the option still wins over the pin.
    cluster.cairn.kubeconfig.kubectl =
      lib.mkDefault
        (release {
          inherit lib pkgs;
          version = v;
        }).kubectl;
  };
}
