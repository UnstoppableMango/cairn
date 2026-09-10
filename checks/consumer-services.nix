# Regression check for #37: `inoculant`, `flux` and `kubelet` are the
# services that close over cairn's *own* flake inputs (`inoculant` / `a2b` /
# `kubepkgs`). If those are reached through a module argument that only
# exists inside cairn's own flake.nix (e.g. an `inputs` specialArg),
# resolving the service blows up with `error: attribute 'inputs' missing`,
# but only once a machine is actually assigned one of the roles, since
# `importApply` is lazy.
#
# This is an *evaluation-only* check rather than extra roles on the
# single-node VM test: `flux` needs a real GitOps git repository to sync
# from, which a sandboxed, network-less VM test can't provide, and its
# manifest bundle is built via IFD. Forcing the two NixOS options that pull
# `inoculant` / `a2b` into scope is enough to catch the breakage without
# booting anything.
{
  cairnModules,
  clan-core,
  nixpkgs,
  pkgs,
}:
let
  inherit (pkgs.stdenv.hostPlatform) system;

  consumer = clan-core.lib.clan {
    self.inputs = {
      cairn.clan.modules = cairnModules;
      inherit nixpkgs;
    };

    directory = ./.;

    imports = [ (import ../examples/single-node/inventory.nix { }) ];

    inventory.meta.name = "consumer-services";

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

  probe = {
    inoculant = builtins.unsafeDiscardStringContext "${cfg.pkg}";
    # The single-node example pins no version, so this must still be
    # nixpkgs' kubernetes; forcing it walks kubelet's version module.
    kubelet = builtins.unsafeDiscardStringContext "${node1.services.kubernetes.package}";
    flux =
      assert cfg.manifestFiles != [ ];
      map (drv: builtins.unsafeDiscardStringContext "${drv}") cfg.manifestFiles;
  };
in
pkgs.runCommand "cairn-consumer-services" { } ''
  ${builtins.deepSeq probe ":"}
  touch "$out"
''
