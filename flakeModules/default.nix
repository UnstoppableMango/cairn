{ clan-core }:
{ lib, config, ... }:
let
  cairnLib = import ../lib { inherit lib; };
  lower = import ./cluster/lower.nix { inherit lib cairnLib; };

  clusters = lib.filterAttrs (_: c: c.enable) config.cairn.clusters;

  # Two clusters in one clan would both want an instance called "etcd", so
  # declaring more than one turns on instance-name prefixing.
  multi = lib.length (lib.attrNames clusters) > 1;
in
{
  imports = [ clan-core.flakeModules.default ];

  options.cairn = import ./cluster/options.nix { inherit lib; };

  config = {
    clan.imports = lib.mapAttrsToList (name: lower { inherit name multi; }) clusters;
  };
}
