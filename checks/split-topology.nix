# `etcd1` runs only etcd, `cp1` runs the apiserver without etcd, `lb1` fronts an apiserver it does not run, and `dns1` bootstraps CoreDNS without either.
# Both examples co-locate everything, so nothing else in CI evaluates where certificate declarations, `cluster.cairn.*` options and local-apiserver probes stop lining up; see docs/TOPOLOGY.md.
{
  cairnModules,
  clan-core,
  lib,
  nixpkgs,
  pkgs,
}:
let
  inherit (pkgs.stdenv.hostPlatform) system;

  clusterName = "split-topology";
  etcdIp = "10.10.0.31";
  cpIp = "10.10.0.11";
  lbIp = "10.10.0.41";
  dnsIp = "10.10.0.51";
  serviceClusterIpRange = "10.96.0.0/12";
  vip = "10.10.0.10";
  apiserverPort = 6443;

  mkModule = name: {
    module.name = "@UnstoppableMango/${name}";
    module.input = "cairn";
  };

  consumer = clan-core.lib.clan {
    self.inputs = {
      cairn.clan.modules = cairnModules;
      inherit nixpkgs;
    };

    directory = ./.;

    inventory.meta.name = clusterName;

    inventory.machines = {
      etcd1.tags = [ "etcd" ];
      cp1.tags = [ "control-plane" ];
      lb1.tags = [ "loadbalancer" ];
      dns1.tags = [ "dns" ];
    };

    inventory.instances = {
      pki = mkModule "pki" // {
        roles.node.tags.all = { };
      };

      etcd = mkModule "etcd" // {
        roles.member.machines.etcd1.settings = {
          ip = etcdIp;
          inherit clusterName;
        };
      };

      apiserver = mkModule "apiserver" // {
        roles.control-plane.machines.cp1.settings = {
          ip = cpIp;
          inherit apiserverPort vip clusterName;
        };
      };

      loadbalancer = mkModule "loadbalancer" // {
        roles.control-plane.settings = {
          inherit vip;
          interface = "eth0";
        };
        roles.control-plane.machines.cp1.settings.keepalivedPriority = 150;
        roles.control-plane.machines.lb1.settings.keepalivedPriority = 100;
      };

      kubelet = mkModule "kubelet" // {
        roles.node.machines.cp1.settings = {
          ip = cpIp;
          schedulable = false;
          inherit vip clusterName;
        };
      };

      network = mkModule "network" // {
        roles.node.tags = [ "control-plane" ];
        roles.node.settings = { inherit vip clusterName; };
      };

      kubeconfig = mkModule "kubeconfig" // {
        roles.node.tags = [
          "control-plane"
          "dns"
        ];
        roles.node.settings = { inherit vip clusterName; };
      };

      inoculant = mkModule "inoculant" // {
        roles.node.machines.dns1.settings.nodeLabels = { };
      };

      coredns = mkModule "coredns" // {
        roles.control-plane.machines.dns1 = { };
      };
    };

    machines.etcd1.nixpkgs.hostPlatform = system;
    machines.cp1.nixpkgs.hostPlatform = system;
    machines.lb1.nixpkgs.hostPlatform = system;
    machines.dns1.nixpkgs.hostPlatform = system;

    machines.dns1.cluster.cairn.coredns = {
      # dns1 runs no apiserver, so this is the only place it can come from.
      inherit serviceClusterIpRange;

      # dns1 runs no kubelet, so the default would pin the pods to a machine that is not a node.
      nodeNames = [ "cp1" ];
    };
  };

  etcd1 = consumer.config.nixosConfigurations.etcd1.config;
  cp1 = consumer.config.nixosConfigurations.cp1.config;
  lb1 = consumer.config.nixosConfigurations.lb1.config;
  dns1 = consumer.config.nixosConfigurations.dns1.config;

  trackScriptsOf = machine: machine.services.keepalived.vrrpInstances.VI_K8S.trackScripts;

  apiserver = cp1.services.kubernetes.apiserver;

  # `certs.<name>.cert` is a clan vars path that exists only after `clan vars generate`, so this reads the declaration, whose absence breaks the apiserver's `pki.certs."etcd-client-cert"` lookup.
  clientCertOn = machine: machine.cluster.cairn.pki.certs."etcd-client-cert";

  probe = {
    apiserverEtcdClient =
      assert (clientCertOn cp1).cn == "kube-apiserver-etcd-client";
      (clientCertOn cp1).profile;

    # The generator proves the declaration reaches the machine rather than sitting in a module nothing imports.
    apiserverEtcdClientGenerator =
      cp1.clan.core.vars.generators.cairn-etcd-client-cert.files.crt.secret;

    apiserverEtcdServers =
      assert apiserver.etcd.servers == [ "https://${etcdIp}:2379" ];
      apiserver.etcd.servers;

    etcdMember =
      assert etcd1.services.etcd.initialCluster == [ "etcd1=https://${etcdIp}:2380" ];
      etcd1.services.etcd.initialClusterToken;

    etcdctl = (clientCertOn etcd1).cn;

    # nixpkgs turns these on only through a Kubernetes role: without ExecStart etcd never starts, and without the cert's owner sops-install-secrets installs nothing.
    etcdOnlyMember =
      assert etcd1.services.etcd.enable;
      assert etcd1.systemd.services.etcd.serviceConfig ? ExecStart;
      assert (clientCertOn etcd1).owner == "kubernetes";
      etcd1.users.users.kubernetes.uid;

    # A track script here would fail forever and permanently subtract its weight from the VRRP priority.
    lbWithoutApiserver =
      assert trackScriptsOf lb1 == [ ];
      assert lb1.services.keepalived.vrrpScripts == { };
      lb1.services.keepalived.vrrpInstances.VI_K8S.priority;

    lbBackend =
      assert lib.hasInfix "server ${cpIp}:${toString apiserverPort}" lb1.services.haproxy.config;
      lb1.services.haproxy.enable;

    lbWithApiserver =
      assert trackScriptsOf cp1 == [ "check_apiserver" ];
      assert lib.hasInfix "https://127.0.0.1:${toString apiserverPort}/readyz"
        cp1.services.keepalived.vrrpScripts.check_apiserver.script;
      cp1.services.keepalived.vrrpScripts.check_apiserver.weight;

    corednsClusterIp =
      assert dns1.cluster.cairn.coredns.clusterIp == "10.96.0.254";
      dns1.cluster.cairn.coredns.clusterIp;

    corednsNodeNames =
      assert dns1.cluster.cairn.coredns.nodeNames == [ "cp1" ];
      dns1.cluster.cairn.coredns.nodeNames;

    corednsWithoutKubelet =
      assert dns1.services.kubernetes.kubelet.seedDockerImages == [ ];
      assert dns1.services.kubernetes.inoculant.enable;
      dns1.services.kubernetes.inoculant.manifests;
  };
in
pkgs.runCommand "cairn-split-topology" { } ''
  ${builtins.deepSeq probe ":"}
  touch "$out"
''
