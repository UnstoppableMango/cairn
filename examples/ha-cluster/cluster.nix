# Apart from ./flake.nix so checks/flake-module.nix evaluates the exact spec this example ships.
{
  # Consumer flakes use the name they gave the cairn input; cairn's own checks pass "self".
  moduleInput ? "cairn",
  system ? "x86_64-linux",
}:
{
  inherit moduleInput;

  # Must share an L2 subnet with the control-plane machines, since keepalived uses VRRP.
  vip = "10.10.0.10";

  # Upgrades step this one minor at a time; see docs/UPGRADES.md.
  versions.kubernetes = "1.36";

  machines = {
    cp1 = {
      role = "control-plane";
      ip = "10.10.0.11";
      # Staggered so cp1 holds the VIP by default.
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
      # The node's /24 podCIDR caps this at 254.
      maxPods = 250;
      nodeLabels."example.com/gpu" = "true";
      # This one also runs a storage daemon outside Kubernetes, so it holds back memory the other workers do not.
      systemReserved = {
        cpu = "2";
        memory = "4Gi";
      };
      evictionHard."memory.available" = "1Gi";
    };
    worker2 = {
      role = "worker";
      ip = "10.10.0.22";
      # Per machine, so nodes move over one at a time, each drained first.
      nixSnapshotter = true;
    };
  };

  services = {
    # Enabling this moves the apiservers to 6444, behind HAProxy on 6443.
    loadbalancer = {
      enable = true;
      interface = "eth0";
      virtualRouterId = 51;
    };

    # For pods running their own container runtime under hostUsers: false.
    kubelet.containerdRuntimes.runc-cgroup-writable = {
      runtime_type = "io.containerd.runc.v2";
      cgroup_writable = true;
      options.SystemdCgroup = true;
    };

    metrics-server.enable = true;

    flux = {
      enable = true;
      url = "https://github.com/your-org/example-cluster";
      branch = "main";
      path = "./clusters/example";
    };
  };

  # Substitute each real machine's own hardware configuration; these five are identical placeholders, so it all goes here rather than in `machines.<name>.nixos`.
  nixos = {
    nixpkgs.hostPlatform = system;
    fileSystems."/" = {
      device = "/dev/disk/by-label/nixos";
      fsType = "ext4";
    };
    boot.loader.grub.device = "/dev/sda";
  };
}
