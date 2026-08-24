{ inoculant }:
{
  config,
  lib,
  ...
}:
let
  cfg = config.services.kubernetes.inoculant;
in
{
  imports = [ inoculant.nixosModules.default ];

  config.services.kubernetes.inoculant = {
    enable = lib.mkIf (cfg.nodeLabels != { }) (lib.mkDefault true);

    clusterAdmin = {
      cert = config.cluster.cairn.pki.certs."admin-cert".cert;
      key = config.cluster.cairn.pki.certs."admin-cert".key;
    };
  };
}
