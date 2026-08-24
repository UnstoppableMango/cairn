# The whole cluster, as one `cairn.clusters.<name>` value.
#
# It lives in its own file, apart from ./flake.nix, so cairn's own
# checks/flake-module.nix can evaluate the exact spec this example ships
# rather than a copy of it that could drift.
{
  # Name of the flake input cairn's modules are resolved through. Consumer
  # flakes use the name they gave the input ("cairn", as in ./flake.nix);
  # cairn's own in-repo checks pass "self".
  moduleInput ? "cairn",
  system ? "x86_64-linux",
}:
{
  inherit moduleInput;

  # `clusterName` defaults to the attribute name this is assigned to
  # ("example" in ./flake.nix), so it isn't set here.

  # Floating VIP the loadbalancer manages; every node and client reaches the
  # apiserver here. Must be on the same L2 subnet as the control-plane
  # machines, since keepalived uses VRRP.
  vip = "10.10.0.10";

  machines = {
    cp1 = {
      role = "control-plane";
      ip = "10.10.0.11";
      # Staggered so cp1 holds the VIP by default; any of the three can take
      # it over if cp1 goes down.
      keepalivedPriority = 150;
    };
    cp2 = {
      role = "control-plane";
      ip = "10.10.0.12";
      keepalivedPriority = 100;
    };
    cp3 = {
      role = "control-plane";
      ip = "10.10.0.13";
      keepalivedPriority = 50;
    };
    worker1 = {
      role = "worker";
      ip = "10.10.0.21";
    };
    worker2 = {
      role = "worker";
      ip = "10.10.0.22";
    };
  };

  services = {
    # An HA control plane needs the VIP, so keepalived and HAProxy run on all
    # three control-plane machines. Enabling this also moves the apiservers
    # themselves to port 6444, behind HAProxy on 6443.
    loadbalancer = {
      enable = true;
      interface = "eth0";
      # Only needs changing if another VRRP-managed VIP shares the subnet.
      virtualRouterId = 51;
    };

    # Optional: point Flux at your own GitOps repository. Drop this block
    # entirely if you don't want a GitOps bootstrap.
    flux = {
      enable = true;
      url = "https://github.com/your-org/example-cluster";
      branch = "main";
      path = "./clusters/example";
    };
  };

  # Merged into every machine in the cluster. Substitute each real machine's
  # own hardware configuration (e.g. from `nixos-generate-config`); this
  # example's five machines are identical placeholders, so it all goes here
  # rather than in per-machine `machines.<name>.nixos`.
  nixos = {
    nixpkgs.hostPlatform = system;
    fileSystems."/" = {
      device = "/dev/disk/by-label/nixos";
      fsType = "ext4";
    };
    boot.loader.grub.device = "/dev/sda";
  };
}
