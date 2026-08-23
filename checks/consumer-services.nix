# Regression check for #37: `inoculant` and `flux` are the only two services
# that close over cairn's *own* flake inputs (`inoculant` / `a2b`). If those
# are reached through a module argument that only exists inside cairn's own
# flake.nix (e.g. an `inputs` specialArg), resolving either service blows up
# with `error: attribute 'inputs' missing`, but only once a machine is
# actually assigned one of the two roles, since `importApply` is lazy.
#
# This is an *evaluation-only* check rather than extra roles on the
# single-node VM test: `flux` needs a real GitOps git repository to sync
# from, which a sandboxed, network-less VM test can't provide, and its
# manifest bundle is built via IFD. Forcing the two NixOS options that pull
# `inoculant` / `a2b` into scope is enough to catch the breakage without
# booting anything.
{
  # Cairn's `clan.modules` registry, i.e. exactly what a consumer flake sees
  # as `inputs.cairn.clan.modules` and what clan's resolveModule reads for
  # `module.input = "cairn"`.
  cairnModules,
  clan-core,
  nixpkgs,
  pkgs,
}:
let
  inherit (pkgs.stdenv.hostPlatform) system;

  # A stand-in for a downstream consumer flake: `self` here is the
  # *consumer's* flake, and cairn is one of its inputs (named "cairn", the
  # name examples/single-node/inventory.nix resolves modules through by
  # default). clan reads `config.self.inputs` to resolve `module.input`, so
  # this reproduces a consumer's evaluation without a second flake.
  consumer = clan-core.lib.clan {
    self.inputs = {
      cairn.clan.modules = cairnModules;
      inherit nixpkgs;
    };

    directory = ./.;

    imports = [ (import ../examples/single-node/inventory.nix { }) ];

    inventory.meta.name = "consumer-services";

    # The example inventory deliberately leaves flux out (a single-node
    # smoke-test cluster has nothing to GitOps), so add it here. This check
    # exists precisely to cover the two services nothing else assigns.
    inventory.instances.flux = {
      module.name = "@UnstoppableMango/flux";
      module.input = "cairn";

      roles.control-plane.tags.control-plane = { };
      roles.control-plane.settings.url = "https://example.invalid/gitops.git";
    };

    machines.node1.nixpkgs.hostPlatform = system;
  };

  node1 = consumer.config.nixosConfigurations.node1.config;

  cfg = node1.services.kubernetes.inoculant;

  # Forcing these is what actually demands the two flake inputs:
  #   - `pkg` is declared by `inoculant.nixosModules.default`, which
  #     modules/service/inoculant/node.nix pulls in via `imports`.
  #   - `manifestFiles` here is defined by
  #     modules/service/flux/control-plane.nix, whose manifest bundle is built
  #     from `a2b.legacyPackages.*.lib.flux`.
  # Deliberately *not* probing anything derived from pki certs: those resolve
  # to clan vars paths that only exist after `clan vars generate`, which is
  # the VM test's job, not an evaluation check's.
  #
  # String context is discarded so this stays an evaluation check: the
  # derivations are instantiated, never built.
  probe = {
    inoculant = builtins.unsafeDiscardStringContext "${cfg.pkg}";
    # The assert keeps the flux half from silently going vacuous: an empty
    # manifestFiles would make the map below a no-op that never touches a2b.
    flux =
      assert cfg.manifestFiles != [ ];
      map (drv: builtins.unsafeDiscardStringContext "${drv}") cfg.manifestFiles;
  };
in
pkgs.runCommand "cairn-consumer-services" { } ''
  ${builtins.deepSeq probe ":"}
  touch "$out"
''
