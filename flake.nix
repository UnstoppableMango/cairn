{
  description = "A Kubernetes distribution built on Nix and clan";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";
    systems.url = "github:nix-systems/triplet";

    flake-parts = {
      url = "github:hercules-ci/flake-parts";
      inputs.nixpkgs-lib.follows = "nixpkgs";
    };

    treefmt-nix = {
      url = "github:numtide/treefmt-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    clan-core = {
      url = "https://git.clan.lol/clan/clan-core/archive/26.05.tar.gz";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        systems.follows = "systems";
        flake-parts.follows = "flake-parts";
        treefmt-nix.follows = "treefmt-nix";
      };
    };

    a2b = {
      url = "github:UnstoppableMango/a2b";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        systems.follows = "systems";
        flake-parts.follows = "flake-parts";
        treefmt-nix.follows = "treefmt-nix";
      };
    };

    inoculant = {
      url = "github:UnstoppableMango/inoculant";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        systems.follows = "systems";
        flake-parts.follows = "flake-parts";
        treefmt-nix.follows = "treefmt-nix";
        # a2b already pulls these in (via its own "mangopkgs" input); reuse
        # that copy instead of letting inoculant fetch a second one.
        gomod2nix.follows = "a2b/mangopkgs/gomod2nix";
        nix2container.follows = "a2b/mangopkgs/nix2container";
      };
    };
  };

  outputs =
    inputs@{ flake-parts, ... }:
    let
      cairnFlakeModule = import ./flakeModules/default.nix { cairnInputs = inputs; };
    in
    flake-parts.lib.mkFlake { inherit inputs; } (
      { config, lib, ... }:
      {
        imports = with inputs; [
          treefmt-nix.flakeModule
          flake-parts.flakeModules.modules
          flake-parts.flakeModules.flakeModules
          cairnFlakeModule
          clan-core.flakeModules.testModule
        ];

        flake.flakeModules.default = cairnFlakeModule;
        flake.lib = import ./lib { inherit lib; };
        # clan-core's module resolution (module.input = "self") reads
        # `config.self.inputs` to look up external flake inputs like
        # `inoculant`/`a2b`. The nixosTest driver re-fetches `self` in
        # isolation, where that only resolves if we expose it ourselves.
        flake.inputs = inputs;

        clan = {
          imports = [ ./clan.nix ];
        };

        perSystem =
          { pkgs, ... }:
          {
            devShells.default = pkgs.mkShellNoCC {
              packages = with pkgs; [
                gnumake
                nixfmt
              ];
            };

            clan.nixosTests.single-node-cluster = import ./examples/single-node/tests/vm/default.nix {
              # Reuse this flake's own resolved module registry (the same
              # thing an external consumer gets via `inputs.cairn.clan.modules`)
              # instead of the test importing module source files directly.
              cairnModules = lib.getAttrs [
                "@UnstoppableMango/pki"
                "@UnstoppableMango/etcd"
                "@UnstoppableMango/apiserver"
                "@UnstoppableMango/kubelet"
                "@UnstoppableMango/network"
                "@UnstoppableMango/kubeconfig"
                "@UnstoppableMango/inoculant"
                "@UnstoppableMango/coredns"
              ] config.flake.clan.modules;
            };

            # Evaluation-only coverage for the services no VM test assigns
            # (see checks/consumer-services.nix).
            checks.consumer-services = import ./checks/consumer-services.nix {
              inherit pkgs;
              inherit (inputs) clan-core nixpkgs;
              cairnModules = config.flake.clan.modules;
            };

            treefmt = {
              programs = {
                nixfmt.enable = true;
                mdformat.enable = true;
                yamlfmt.enable = true;
                jsonfmt.enable = true;
                mbake = {
                  enable = true;
                  settings.ensure_final_newline = true;
                };
              };

              settings.formatter.mdformat.excludes = [
                ".agents/skills/**"
                ".claude/skills/**"
              ];
            };
          };
      }
    );
}
