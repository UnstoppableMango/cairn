# Resolves one kubepkgs minor for the machine's platform. The kubelet and
# etcd services pin from the same set, and a minor kubepkgs does not ship
# should name the ones it does rather than fail with a missing attribute.
{ kubepkgs }:
{
  lib,
  pkgs,
  version,
}:
let
  releases = kubepkgs.legacyPackages.${pkgs.stdenv.hostPlatform.system}.kubernetes;
  supported = lib.remove "latest" (lib.attrNames releases);
in
lib.throwIfNot (releases ? ${version})
  "cluster.cairn.kubernetesVersion: kubepkgs does not ship ${version}; supported minors are ${lib.concatStringsSep ", " supported}."
  releases.${version}
