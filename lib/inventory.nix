{ lib }:
{
  mkMachines =
    common: perMachine: lib.mapAttrs (_: overrides: { settings = common // overrides; }) perMachine;

  nodesOf =
    machines:
    lib.mapAttrsToList (name: m: {
      inherit name;
      inherit (m.settings) ip;
    }) machines;
}
