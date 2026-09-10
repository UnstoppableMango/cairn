{ lib }:
{
  allowPrivileged = lib.mkOption {
    type = lib.types.bool;
    default = true;
    description = ''
      Whether to allow pods requesting `securityContext.privileged`.

      CSI node plugins (Ceph RBD and CephFS, cert-manager's csi-driver) and
      Ceph OSD daemons all require it, and hardcode it in their manifests.
      With this disabled the apiserver rejects those pods at admission with
      `Forbidden: disallowed by cluster policy`, which surfaces as a
      DaemonSet that never gets created rather than a pod that fails to
      schedule.

      This overrides the NixOS `services.kubernetes.apiserver.allowPrivileged`
      default of `false`.
    '';
  };

  apiserverPort = lib.mkOption {
    type = lib.types.port;
    default = 6444;
    description = "Port the local apiserver binds to (fronted externally by loadbalancer at the VIP).";
  };

  serviceClusterIP = lib.mkOption {
    type = lib.types.str;
    default = "10.0.0.1";
    description = "First IP of the service CIDR; included in apiserver SANs.";
  };
}
