{ lib }:
{
  # Merge settings shared across machines with each machine's own overrides,
  # producing `roles.<role>.machines.<name> = { settings = ...; }` entries
  # ready to splice into a clan inventory instance.
  mkMachines =
    common: perMachine: lib.mapAttrs (_: overrides: { settings = common // overrides; }) perMachine;

  # `roles.<role>.machines` → the `[ { name; ip; } ]` shape `options.mkNodes`
  # declares. Every role that carries a per-machine `ip` setting feeds its
  # NixOS module this way.
  nodesOf =
    machines:
    lib.mapAttrsToList (name: m: {
      inherit name;
      inherit (m.settings) ip;
    }) machines;
}
