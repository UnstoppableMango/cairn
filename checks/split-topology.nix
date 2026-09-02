# Coverage for a topology where services do not share machines the way both
# examples assume: `etcd1` runs etcd and nothing else, `cp1` runs the
# apiserver without being an etcd member, `lb1` fronts the apiserver without
# running one, and `dns1` bootstraps CoreDNS without either. See
# docs/TOPOLOGY.md.
#
# Both examples are maximal co-location cases (single-node runs everything on
# one machine, ha-cluster puts every control-plane service on every
# control-plane machine), so nothing else in CI evaluates a machine that has
# one of these services without the others. That is precisely where the
# certificate declarations, the `cluster.cairn.*` option declarations, and
# the probes that assume a local apiserver stop lining up.
#
# Evaluation-only, like ./consumer-services.nix and ./flake-module.nix: the
# breakage is a missing attribute at eval time, and booting two machines
# would prove nothing further.
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

      # The whole point: the member is on a machine with no apiserver.
      etcd = mkModule "etcd" // {
        roles.member.machines.etcd1.settings = {
          ip = etcdIp;
          inherit clusterName;
        };
      };

      # ...and the apiserver is on a machine with no etcd member.
      apiserver = mkModule "apiserver" // {
        roles.control-plane.machines.cp1.settings = {
          ip = cpIp;
          inherit apiserverPort vip clusterName;
        };
      };

      # cp1 fronts its own apiserver, lb1 fronts one it does not run.
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
          # cp1 runs an apiserver, so it is a node without being a target
          # for pods.
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
      # The service CIDR a consumer would set alongside the apiserver's own.
      # dns1 runs no apiserver, so this is the only place it can come from.
      inherit serviceClusterIpRange;

      # dns1 applies the manifests but runs no kubelet, so the pods have to
      # be pinned somewhere else. cp1 runs one, and the manifest's
      # master/unschedulable tolerations cover its control-plane taint.
      # Without this the default would pin them to dns1, a machine that is
      # not a node at all.
      nodeNames = [ "cp1" ];
    };
  };

  etcd1 = consumer.config.nixosConfigurations.etcd1.config;
  cp1 = consumer.config.nixosConfigurations.cp1.config;
  lb1 = consumer.config.nixosConfigurations.lb1.config;
  dns1 = consumer.config.nixosConfigurations.dns1.config;

  trackScriptsOf = machine: machine.services.keepalived.vrrpInstances.VI_K8S.trackScripts;

  apiserver = cp1.services.kubernetes.apiserver;

  # `certs.<name>.cert` resolves to a path clan's vars machinery only
  # produces once `clan vars generate` has run, so an evaluation-only check
  # reads the declaration rather than the generated file. Missing the
  # declaration is the failure being guarded against either way: the
  # apiserver's `pki.certs."etcd-client-cert"` lookup is what breaks.
  clientCertOn = machine: machine.cluster.cairn.pki.certs."etcd-client-cert";

  probe = {
    # The etcd client certificate on a machine that runs the apiserver and is
    # not an etcd member.
    apiserverEtcdClient =
      assert (clientCertOn cp1).cn == "kube-apiserver-etcd-client";
      (clientCertOn cp1).profile;

    # The generator pki builds from that declaration, proving it reaches the
    # machine rather than merely being declared in a module nothing imports.
    apiserverEtcdClientGenerator =
      cp1.clan.core.vars.generators.cairn-etcd-client-cert.files.crt.secret;

    # The endpoint reaches cp1 across machines, through the etcd service's
    # export rather than through co-location.
    apiserverEtcdServers =
      assert apiserver.etcd.servers == [ "https://${etcdIp}:2379" ];
      apiserver.etcd.servers;

    # etcd on a machine with no apiserver, and so no `cluster.cairn.vip`.
    etcdMember =
      assert etcd1.services.etcd.initialCluster == [ "etcd1=https://${etcdIp}:2380" ];
      etcd1.services.etcd.initialClusterToken;

    # etcd still gets the shared client cert for its own etcdctl.
    etcdctl = (clientCertOn etcd1).cn;

    # A loadbalancer machine with no apiserver runs no keepalived track
    # script: the probe would fail forever and permanently subtract the
    # script's weight from this machine's VRRP priority.
    lbWithoutApiserver =
      assert trackScriptsOf lb1 == [ ];
      assert lb1.services.keepalived.vrrpScripts == { };
      lb1.services.keepalived.vrrpInstances.VI_K8S.priority;

    # It still fronts the apiserver it does not run, through the export.
    lbBackend =
      assert lib.hasInfix "server ${cpIp}:${toString apiserverPort}" lb1.services.haproxy.config;
      lb1.services.haproxy.enable;

    # Where an apiserver *is* co-located the track script stays, and reads
    # the local apiserver's own port rather than a backend entry's.
    lbWithApiserver =
      assert trackScriptsOf cp1 == [ "check_apiserver" ];
      assert lib.hasInfix "https://127.0.0.1:${toString apiserverPort}/readyz"
        cp1.services.keepalived.vrrpScripts.check_apiserver.script;
      cp1.services.keepalived.vrrpScripts.check_apiserver.weight;

    # CoreDNS derives its ClusterIP from the service CIDR it is given, not
    # from the local apiserver's config, which a machine that only
    # bootstraps the manifests does not have.
    corednsClusterIp =
      assert dns1.cluster.cairn.coredns.clusterIp == "10.96.0.254";
      dns1.cluster.cairn.coredns.clusterIp;

    # The pods are pinned to the machine that runs a kubelet, not to the one
    # that applied the manifests.
    corednsNodeNames =
      assert dns1.cluster.cairn.coredns.nodeNames == [ "cp1" ];
      dns1.cluster.cairn.coredns.nodeNames;

    # ...and it seeds no image where there is no kubelet to seed it into.
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
