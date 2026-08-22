{
  config,
  lib,
  ...
}:
let
  cfg = config.cluster.cairn.kubelet;
  pki = config.cluster.cairn.pki;

  cairnOptions = import ../../../lib/options.nix { inherit lib; };

  apiServerURL = "https://${cfg.vip}:6443";
in
{
  imports = [ ./common.nix ];

  options.cluster.cairn.kubelet = {
    vip = cairnOptions.vip;
    clusterName = cairnOptions.clusterName;
  };

  config.services.kubernetes = {
    roles = [ "node" ];
    masterAddress = cfg.vip;
    apiserverAddress = apiServerURL;
    easyCerts = false;
    caFile = pki.ca.cert;
  };
}
