{
  config,
  lib,
  inputs,
  ...
}:
let
  cfg = config.cluster.cairn.loadbalancer;
in
{
  options.cluster.cairn.loadbalancer = {
    vip = inputs.self.lib.options.vip;

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
      description = "VRRP priority — highest wins the VIP.";
    };

    apiserverBackends = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      description = "apiserver backend dial targets (\"ip:port\"), from the apiserver service's exports.";
    };
  };

  config = {
    # -------------------------------------------------------------------------
    # keepalived — floating VIP
    # -------------------------------------------------------------------------
    services.keepalived = {
      enable = true;
      openFirewall = true;
      vrrpInstances.VI_K8S = {
        interface = cfg.interface;
        state = "BACKUP";
        virtualRouterId = cfg.virtualRouterId;
        priority = cfg.keepalivedPriority;
        virtualIps = [ { addr = "${cfg.vip}/24"; } ];
      };
    };

    # -------------------------------------------------------------------------
    # HAProxy — LB from VIP:6443 → apiserver nodes
    # -------------------------------------------------------------------------
    services.haproxy = {
      enable = true;
      config = ''
        global
          log /dev/log local0
          maxconn 4000

        defaults
          log global
          mode tcp
          timeout connect 5s
          timeout client 1h
          timeout server 1h
          timeout tunnel 1h

        frontend k8s-api
          bind *:6443
          default_backend k8s-api-backend

        backend k8s-api-backend
          balance roundrobin
          option tcp-check
          ${lib.concatMapStringsSep "\n          " (
            backend: "server ${backend} ${backend} check"
          ) cfg.apiserverBackends}
      '';
    };

    networking.firewall.allowedTCPPorts = [
      6443 # HAProxy (external VIP)
    ];
  };
}
