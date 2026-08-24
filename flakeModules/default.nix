# `cairnInputs` (not `inputs`) is deliberate: an `{ inputs, ... }:` module arg
# gets rebound by flake-parts to the *consumer's own* inputs when imported
# unmodified into their `mkFlake`, so `inputs.clan-core` wouldn't resolve
# there. clan-core's own flake-module.nix uses the same `coreInputs` pattern.
{ cairnInputs }:
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
  imports = [ cairnInputs.clan-core.flakeModules.default ];

  options.cairn = import ./cluster/options.nix { inherit lib; };

  config = {
    systems = lib.mkDefault (import cairnInputs.systems);

    clan.imports = lib.mapAttrsToList (name: lower { inherit name multi; }) clusters;
  };
}
