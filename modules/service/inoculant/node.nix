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
    # Labels alone are a reason to run inoculant: without this, a machine
    # assigned this role but neither coredns nor flux (the only other things
    # that enable it) would silently never apply them. mkDefault so an
    # explicit `enable = false` still wins.
    enable = lib.mkIf (cfg.nodeLabels != { }) (lib.mkDefault true);

    clusterAdmin = {
      cert = config.cluster.cairn.pki.certs."admin-cert".cert;
      key = config.cluster.cairn.pki.certs."admin-cert".key;
    };
  };
}
