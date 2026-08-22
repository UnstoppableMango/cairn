# Consumer flakes import this to configure cairn with minimal boilerplate:
# `imports = [ inputs.cairn.flakeModules.default ];`
#
# `cairnInputs` is bound by lexical closure over cairn's OWN `inputs` (passed
# in from flake.nix's `outputs` function), not injected by the flake-parts
# module system. This is deliberate: if this file instead read
# `{ inputs, lib, ... }: { imports = [ inputs.clan-core.flakeModules.default ]; ... }`
# and got imported unmodified into a consumer's `mkFlake`, flake-parts would
# rebind `inputs` to the *consumer's own* flake inputs for that module
# evaluation, and `inputs.clan-core` wouldn't exist there unless the consumer
# separately declared their own `clan-core` input, defeating the point.
# Keeping cairn's own inputs under a differently-named parameter
# (`cairnInputs`) avoids this shadowing trap. clan-core's own
# `flakeModules/flake-module.nix` uses the identical pattern (passes its own
# inputs through as `coreInputs`, distinct from the module-arg `inputs`).
{ cairnInputs }:
{ lib, ... }:
{
  imports = [ cairnInputs.clan-core.flakeModules.default ];

  systems = lib.mkDefault (import cairnInputs.systems);
}
