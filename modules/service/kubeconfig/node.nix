{
  config,
  lib,
  pkgs,
  inputs,
  ...
}:
let
  cfg = config.cluster.cairn.kubeconfig;
  pki = config.cluster.cairn.pki;
  kubeconfigLib = inputs.self.lib.kubeconfig;
  kubeconfigPath = "/etc/kubernetes/admin.kubeconfig";

  apiServerURL = "https://${cfg.vip}:6443";
in
{
  options.cluster.cairn.kubeconfig = {
    vip = inputs.self.lib.options.vip;
    clusterName = inputs.self.lib.options.clusterName;
  };

  config = {
    cluster.cairn.pki.certs.admin-cert = {
      cn = "kubernetes-admin";
      org = "system:masters";
      profile = "client";
      owner = "root";
    };

    environment.etc."kubernetes/admin.kubeconfig" = {
      mode = "0600";
      text = kubeconfigLib.mkKubeconfig {
        ca = pki.ca.cert;
        server = apiServerURL;
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
