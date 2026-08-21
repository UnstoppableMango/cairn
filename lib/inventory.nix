{ lib }:
{
  # Merge settings shared across machines with each machine's own overrides,
  # producing `roles.<role>.machines.<name> = { settings = ...; }` entries
  # ready to splice into a clan inventory instance.
  mkMachines =
    common: perMachine: lib.mapAttrs (_: overrides: { settings = common // overrides; }) perMachine;
}
