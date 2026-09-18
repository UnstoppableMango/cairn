{
  config,
  lib,
  ...
}:
let
  cfg = config.cluster.cairn.kubelet;
  pki = config.cluster.cairn.pki;
in
{
  options.cluster.cairn.kubelet = {
    advertiseAddress = lib.mkOption {
      type = lib.types.str;
      description = "IP address this node advertises for kubelet (included in the kubelet server certificate's SAN).";
    };

    schedulable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Whether pods may be scheduled onto this node.";
    };

    rootDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/kubelet";
      description = ''
        kubelet's `--root-dir`, where it keeps per-pod volume state and the
        CSI plugin and registration sockets.

        `/var/lib/kubelet` is the upstream default and the path CSI drivers
        hardcode as `hostPath` mounts (`plugins`, `plugins_registry`, `pods`),
        with a `Directory` type that fails rather than creating what's
        missing. nixpkgs instead points `--root-dir` at
        `services.kubernetes.dataDir`, which defaults to
        `/var/lib/kubernetes`, so a stock NixOS cluster cannot run a CSI
        driver until this is set back.

        Point it at `services.kubernetes.dataDir` on a cluster that already
        has live pod state under the nixpkgs path and cannot take the
        relocation.
      '';
    };
  };

  config = {
    cluster.cairn.pki.certs = {
      kubelet-cert = {
        cn = "system:node:${config.networking.hostName}";
        org = "system:nodes";
        hosts = [ cfg.advertiseAddress ];
        share = false;
        profile = "peer";
        owner = "root";
      };
      kubelet-client-cert = {
        cn = "system:node:${config.networking.hostName}";
        org = "system:nodes";
        share = false;
        profile = "client";
        owner = "root";
      };
    };

    services.kubernetes.kubelet = {
      # clan sets meta.domain, which causes networking.fqdnOrHostName to return
      # e.g. "node1.example.com". The NixOS kubelet default uses fqdnOrHostName,
      # but cert CNs are generated from the short hostname ("system:node:node1").
      # Node Authorizer rejects: cert subject "node1" cannot read node "node1.example.com".
      hostname = config.networking.hostName;
      # nixpkgs hardcodes --root-dir=${services.kubernetes.dataDir} with no
      # option of its own, and emits it ahead of extraOpts. A second --root-dir
      # wins, since pflag overwrites a scalar flag on repeat.
      extraOpts = "--root-dir=${cfg.rootDir}";
      clientCaFile = pki.ca.cert;
      tlsCertFile = pki.certs."kubelet-cert".cert;
      tlsKeyFile = pki.certs."kubelet-cert".key;
      kubeconfig = {
        certFile = pki.certs."kubelet-client-cert".cert;
        keyFile = pki.certs."kubelet-client-cert".key;
      };
    };

    services.kubernetes.proxy.kubeconfig = {
      certFile = pki.certs."kube-proxy-cert".cert;
      keyFile = pki.certs."kube-proxy-cert".key;
    };

    networking.firewall.allowedTCPPorts = [
      10250
    ];
  };
}
