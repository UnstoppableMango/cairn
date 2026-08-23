{ cairnLib }:
{
  config,
  pkgs,
  ...
}:
let
  cfg = config.cluster.cairn;
  pki = cfg.pki;
  kubeconfigPath = "/etc/kubernetes/admin.kubeconfig";
in
{
  imports = [ ../cluster.nix ];

  config = {
    cluster.cairn.pki.certs.admin-cert = {
      cn = "kubernetes-admin";
      org = "system:masters";
      profile = "client";
      owner = "root";
    };

    environment.etc."kubernetes/admin.kubeconfig" = {
      mode = "0600";
      text = cairnLib.kubeconfig.mkKubeconfig {
        ca = pki.ca.cert;
        server = cfg.apiServerURL;
        clusterName = cfg.clusterName;
        userName = "kubernetes-admin";
        certFile = pki.certs."admin-cert".cert;
        keyFile = pki.certs."admin-cert".key;
      };
    };

    environment.systemPackages = [ pkgs.kubectl ];

    environment.variables.KUBECONFIG = kubeconfigPath;
  };
}
