{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.cluster.cairn;
  rosLib = import ./lib.nix;
  kubeconfigPath = "/etc/kubernetes/admin.kubeconfig";
in
{
  options.cluster.cairn.kubeconfig.enable = lib.mkOption {
    type = lib.types.bool;
    default = true;
    description = "Whether to install an admin kubeconfig at ${kubeconfigPath} on this node.";
  };

  config = lib.mkIf cfg.kubeconfig.enable {
    cluster.cairn.pki.certs.admin-cert = {
      cn = "kubernetes-admin";
      org = "system:masters";
      profile = "client";
      owner = "root";
    };

    environment.etc."kubernetes/admin.kubeconfig" = {
      mode = "0600";
      text = rosLib.mkKubeconfig {
        ca = cfg.pki.ca.cert;
        server = cfg.apiServerURL;
        clusterName = cfg.clusterName;
        userName = "kubernetes-admin";
        certFile = cfg.pki.certs."admin-cert".cert;
        keyFile = cfg.pki.certs."admin-cert".key;
      };
    };

    environment.systemPackages = [ pkgs.kubectl ];

    environment.variables.KUBECONFIG = kubeconfigPath;
  };
}
