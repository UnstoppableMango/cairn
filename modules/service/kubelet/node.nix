{
  config,
  lib,
  ...
}:
let
  cfg = config.cluster.cairn;
  pki = cfg.pki;
in
{
  imports = [
    ./common.nix
    ../cluster.nix
  ];

  config.services.kubernetes = {
    # `master` comes from the apiserver service where one runs alongside.
    # This role only ever adds `node`, and only where pods are wanted.
    roles = lib.optional cfg.kubelet.schedulable "node";
    masterAddress = cfg.vip;
    apiserverAddress = cfg.apiServerURL;
    easyCerts = false;
    caFile = pki.ca.cert;
  };

  # Containers inherit containerd's soft RLIMIT_NOFILE, and without this that
  # is systemd's 1024. Software that does not raise its own soft limit, such
  # as Ceph's radosgw, runs out of descriptors under load. 1048576 is what
  # k3s and containerd 1.x shipped.
  config.systemd.services.containerd.serviceConfig =
    lib.mkIf config.virtualisation.containerd.enable
      {
        LimitNOFILE = lib.mkDefault 1048576;
      };
}
