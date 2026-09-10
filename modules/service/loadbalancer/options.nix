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

  healthCheck = lib.mkOption {
    type = lib.types.submodule {
      options = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = ''
            Probe apiserver readiness rather than TCP reachability: HAProxy
            checks each backend's `/readyz`, and keepalived tracks the local
            apiserver so the VIP moves off a machine whose apiserver is
            unready, not only one whose keepalived is down.
          '';
        };

        interval = lib.mkOption {
          type = lib.types.ints.positive;
          default = 2;
          description = "Seconds between keepalived probes of the local apiserver.";
        };

        fall = lib.mkOption {
          type = lib.types.ints.positive;
          default = 3;
          description = "Consecutive failed probes before keepalived marks the apiserver down.";
        };

        rise = lib.mkOption {
          type = lib.types.ints.positive;
          default = 2;
          description = "Consecutive successful probes before keepalived marks the apiserver up again.";
        };

        weight = lib.mkOption {
          type = lib.types.ints.positive;
          default = 60;
          description = ''
            Amount subtracted from the VRRP priority while the local apiserver
            is unready. Must exceed the priority gap between any two machines
            for the VIP to move.
          '';
        };
      };
    };
    default = { };
    description = "Apiserver readiness probing for HAProxy backends and the keepalived VIP election.";
  };
}
