{ clan-core }:
{ lib, config, ... }:
let
  cairnLib = import ../lib { inherit lib; };
  lower = import ./cluster/lower.nix { inherit lib cairnLib; };
  plan = import ./cluster/plan.nix { inherit lib; };

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

    # What `cairn-upgrade` walks: `nix eval .#cairn-upgrade-plan.<cluster>`.
    flake.cairn-upgrade-plan = lib.mapAttrs (
      _: cluster:
      plan {
        inherit cluster;
        targetHostOf = m: config.flake.nixosConfigurations.${m}.config.clan.core.networking.targetHost;
      }
    ) clusters;

    perSystem =
      { pkgs, system, ... }:
      {
        packages = lib.optionalAttrs ((clan-core.packages.${system} or { }) ? clan-cli) {
          cairn-upgrade = pkgs.callPackage ../pkgs/upgrade {
            inherit (clan-core.packages.${system}) clan-cli;
          };
        };
      };
  };
}
