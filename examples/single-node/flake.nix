{
  description = "Minimal single-node Kubernetes cluster on cairn";

  inputs = {
    cairn.url = "path:../..";
    nixpkgs.follows = "cairn/nixpkgs";
    flake-parts.follows = "cairn/flake-parts";
  };

  outputs =
    inputs@{ flake-parts, cairn, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      imports = [ cairn.flakeModules.default ];

      # Hand-written `inventory.instances`, to show the low-level path; examples/ha-cluster uses `cairn.clusters`.
      clan = {
        imports = [ (import ./inventory.nix { }) ];

        machines.node1 = {
          nixpkgs.hostPlatform = "x86_64-linux";
          fileSystems."/" = {
            device = "/dev/disk/by-label/nixos";
            fsType = "ext4";
          };
          boot.loader.grub.device = "/dev/sda";

          # nixpkgs taints a master-only node unschedulable, and there is no separate worker here.
          services.kubernetes.roles = [ "node" ];
        };
      };
    };
}
