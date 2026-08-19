{
  config,
  pkgs,
  ...
}:
let
  cfg = config.cluster.rosequartz;
  rosLib = import ./lib.nix;
  kubeconfigPath = "/etc/kubernetes/admin.kubeconfig";
in
{
  config = {
    cluster.rosequartz.pki.certs.admin-cert = {
      cn = "kubernetes-admin";
      org = "system:masters";
      profile = "client";
      owner = "root";
    };

    environment.etc."kubernetes/admin.kubeconfig" = {
      mode = "0600";
      text = rosLib.mkKubeconfig {
        ca = cfg.pki.ca.cert;
        server = "https://${cfg.vip}:6443";
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
