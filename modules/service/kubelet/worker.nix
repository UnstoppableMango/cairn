{
  config,
  lib,
  inputs,
  ...
}:
let
  cfg = config.cluster.cairn.kubelet;
  pki = config.cluster.cairn.pki;

  apiServerURL = "https://${cfg.vip}:6443";
in
{
  imports = [ ./common.nix ];

  options.cluster.cairn.kubelet = {
    vip = inputs.self.lib.options.vip;
    clusterName = inputs.self.lib.options.clusterName;
  };

  config.services.kubernetes = {
    roles = [ "node" ];
    masterAddress = cfg.vip;
    apiserverAddress = apiServerURL;
    easyCerts = false;
    caFile = pki.ca.cert;
  };
}
