# Regression check for #37: these services close over cairn's own flake inputs, and reaching them through an argument that exists only inside cairn's flake.nix fails with `attribute 'inputs' missing`, but only once a machine takes a role, since `importApply` is lazy.
# Evaluation-only because `flux` needs a real GitOps repository, which a network-less VM test cannot provide.
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
    # The single-node example pins no version, so forcing these walks the version modules on nixpkgs' kubernetes and etcd.
    kubelet = builtins.unsafeDiscardStringContext "${node1.services.kubernetes.package}";
    etcd = builtins.unsafeDiscardStringContext "${node1.services.etcd.package}";
    kubectl = builtins.unsafeDiscardStringContext "${node1.cluster.cairn.kubeconfig.kubectl}";
    flux =
      assert cfg.manifestFiles != [ ];
      map (drv: builtins.unsafeDiscardStringContext "${drv}") cfg.manifestFiles;
  };
in
pkgs.runCommand "cairn-consumer-services" { } ''
  ${builtins.deepSeq probe ":"}
  touch "$out"
''
