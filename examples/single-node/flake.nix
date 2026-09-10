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

      # This example deliberately leaves `cairn.clusters` unset and writes its
      # `inventory.instances` out by hand (./inventory.nix) to show the
      # low-level path. examples/ha-cluster shows the same job done through
      # the `cairn.clusters` options.
      clan = {
        imports = [ (import ./inventory.nix { }) ];

        machines.node1 = {
          nixpkgs.hostPlatform = "x86_64-linux";
          fileSystems."/" = {
            device = "/dev/disk/by-label/nixos";
            fsType = "ext4";
          };
          boot.loader.grub.device = "/dev/sda";

          # A control-plane-only node (services.kubernetes.roles = ["master"])
          # is tainted and unschedulable by nixpkgs' kubernetes module unless
          # "node" is also in roles. There's no separate worker machine here,
          # so add it directly so pods can actually schedule onto node1.
          services.kubernetes.roles = [ "node" ];
        };
      };
    };
}
