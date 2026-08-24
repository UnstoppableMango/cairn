{
  config,
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
    roles = [ "node" ];
    masterAddress = cfg.vip;
    apiserverAddress = cfg.apiServerURL;
    easyCerts = false;
    caFile = pki.ca.cert;
  };
}
