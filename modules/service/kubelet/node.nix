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
}
