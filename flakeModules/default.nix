# `cairnInputs` (not `inputs`) is deliberate: an `{ inputs, ... }:` module arg
# gets rebound by flake-parts to the *consumer's own* inputs when imported
# unmodified into their `mkFlake`, so `inputs.clan-core` wouldn't resolve
# there. clan-core's own flake-module.nix uses the same `coreInputs` pattern.
{ cairnInputs }:
{ lib, ... }:
{
  imports = [ cairnInputs.clan-core.flakeModules.default ];

  systems = lib.mkDefault (import cairnInputs.systems);
}
