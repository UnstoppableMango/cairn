{
  description = "Five-machine HA Kubernetes cluster on cairn";

  inputs = {
    cairn.url = "path:../..";
    nixpkgs.follows = "cairn/nixpkgs";
    flake-parts.follows = "cairn/flake-parts";
  };

  outputs =
    inputs@{ flake-parts, cairn, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      # Brings in clan-core, a default `systems` list, and the
      # `cairn.clusters` options below. No `clan-core` input of our own needed.
      imports = [ cairn.flakeModules.default ];

      # The attribute name is the Kubernetes cluster name.
      cairn.clusters.example = import ./cluster.nix { };
    };
}
