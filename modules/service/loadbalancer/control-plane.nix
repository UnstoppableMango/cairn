{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.cluster.cairn.loadbalancer;
  cluster = config.cluster.cairn;
  hc = cfg.healthCheck;

  # The keepalived track script asks whether *this* machine's apiserver is
  # ready, so it is only meaningful where one runs. A loadbalancer machine
  # without an apiserver would fail the probe forever and hand its VIP
  # priority away permanently.
  apiserverColocated = config.services.kubernetes.apiserver.enable;
  localApiserverPort = toString config.services.kubernetes.apiserver.securePort;

  trackApiserver = hc.enable && apiserverColocated;

  backends =
    lib.throwIf (cfg.apiserverBackends == [ ])
      "cluster.cairn.loadbalancer.apiserverBackends is empty, so HAProxy would front no apiserver at all. Assign the apiserver service somewhere in the cluster so its endpoints export reaches this machine."
      cfg.apiserverBackends;

  backendCheck =
    if hc.enable then
      ''
        option httpchk GET /readyz
          http-check expect status 200''
    else
      "option tcp-check";

  serverFlags = "check" + lib.optionalString hc.enable " check-ssl verify none";
in
{
  imports = [ ../cluster.nix ];

  options.cluster.cairn.loadbalancer = (import ./options.nix { inherit lib; }) // {
    apiserverBackends = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      description = "apiserver backend dial targets (\"ip:port\"), from the apiserver service's exports.";
    };
  };

  config = {
    services.keepalived = {
      enable = true;
      openFirewall = true;
      vrrpInstances.VI_K8S = {
        interface = cfg.interface;
        state = "BACKUP";
        virtualRouterId = cfg.virtualRouterId;
        priority = cfg.keepalivedPriority;
        virtualIps = [ { addr = "${cluster.vip}/24"; } ];
        trackScripts = lib.optional trackApiserver "check_apiserver";
      };

      vrrpScripts = lib.mkIf trackApiserver {
        check_apiserver = {
          # The apiserver's cert isn't checked: this asks "is the local
          # apiserver ready", and TLS identity is the client's concern.
          script = "${pkgs.curl}/bin/curl -sfk -o /dev/null --max-time 2 https://127.0.0.1:${localApiserverPort}/readyz";
          interval = hc.interval;
          fall = hc.fall;
          rise = hc.rise;
          weight = -hc.weight;
        };
      };
    };

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
          bind *:${toString cluster.apiServerPort}
          default_backend k8s-api-backend

        backend k8s-api-backend
          balance roundrobin
          ${backendCheck}
          ${lib.concatMapStringsSep "\n          " (
            backend: "server ${backend} ${backend} ${serverFlags}"
          ) backends}
      '';
    };

    networking.firewall.allowedTCPPorts = [
      cluster.apiServerPort
    ];
  };
}
