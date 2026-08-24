{ lib }:
{
  interface = lib.mkOption {
    type = lib.types.str;
    description = "Network interface for keepalived VRRP.";
  };

  virtualRouterId = lib.mkOption {
    type = lib.types.int;
    default = 50;
    description = "Keepalived VRRP virtual router ID (1-255, unique per subnet).";
  };

  keepalivedPriority = lib.mkOption {
    type = lib.types.int;
    default = 100;
    description = "VRRP priority, highest wins the VIP.";
  };
}
