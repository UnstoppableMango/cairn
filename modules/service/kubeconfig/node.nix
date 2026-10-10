{ cairnLib }:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.cluster.cairn;
  pki = cfg.pki;
  kubeconfigPath = "/etc/kubernetes/admin.kubeconfig";

  # `KUBECONFIG` below reaches login shells only; `sudo` resets it. The wrapper
  # supplies it as a default, so a value already set still wins.
  kubectl = pkgs.symlinkJoin {
    name = "kubectl-admin";
    paths = [ cfg.kubeconfig.kubectl ];
    nativeBuildInputs = [ pkgs.makeWrapper ];
    postBuild = ''
      wrapProgram $out/bin/kubectl --set-default KUBECONFIG ${kubeconfigPath}
    '';
  };
in
{
  imports = [
    ../admin.nix
    ../cluster.nix
  ];

  options.cluster.cairn.kubeconfig.kubectl = lib.mkOption {
    type = lib.types.package;
    default = pkgs.kubectl;
    defaultText = lib.literalExpression "pkgs.kubectl";
    description = "kubectl installed on the machine. A pinned Kubernetes minor supplies the matching one; see version.nix.";
  };

  config = {
    cluster.cairn.pki.certs.admin-cert = {
      cn = "kubernetes-admin";
      org = "system:masters";
      profile = "client";
      owner = "root";
      group = cfg.adminGroup;
    };

    environment.etc."kubernetes/admin.kubeconfig" = {
      mode = if cfg.adminGroup == null then "0600" else "0640";
      group = lib.mkIf (cfg.adminGroup != null) cfg.adminGroup;
      text = cairnLib.kubeconfig.mkKubeconfig {
        ca = pki.ca.cert;
        server = cfg.apiServerURL;
        clusterName = cfg.clusterName;
        userName = "kubernetes-admin";
        certFile = pki.certs."admin-cert".cert;
        keyFile = pki.certs."admin-cert".key;
      };
    };

    environment.systemPackages = [ kubectl ];

    environment.variables.KUBECONFIG = kubeconfigPath;
  };
}
