{
  description = "Minimal single-node Kubernetes cluster on cairn";

  inputs = {
    cairn.url = "path:../..";
    nixpkgs.follows = "cairn/nixpkgs";
    flake-parts.follows = "cairn/flake-parts";
    clan-core.follows = "cairn/clan-core";
  };

  outputs =
    inputs@{ flake-parts, clan-core, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      imports = [ clan-core.flakeModules.default ];

      clan = {
        imports = [ (import ./inventory.nix { }) ];

        machines.node1 = {
          # Substitute the real target machine's platform and hardware
          # config (e.g. from `nixos-generate-config` on the real machine).
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
