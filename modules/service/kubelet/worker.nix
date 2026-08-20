{
  config,
  lib,
  ...
}:
let
  cfg = config.cluster.cairn.kubelet;
  pki = config.cluster.cairn.pki;
  commonOptions = import ../lib/options.nix { inherit lib; };

  apiServerURL = "https://${cfg.vip}:6443";
in
{
  imports = [ ./common.nix ];

  options.cluster.cairn.kubelet = {
    vip = commonOptions.vip;
    clusterName = commonOptions.clusterName;
  };

  config.services.kubernetes = {
    roles = [ "node" ];
    masterAddress = cfg.vip;
    apiserverAddress = apiServerURL;
    easyCerts = false;
    caFile = pki.ca.cert;
  };
}
