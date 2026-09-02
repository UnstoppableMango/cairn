# Coverage for a topology where etcd does not share machines with the
# apiserver: `etcd1` runs etcd and nothing else, `cp1` runs the apiserver
# without being an etcd member. See docs/TOPOLOGY.md.
#
# Both examples are maximal co-location cases (single-node runs everything on
# one machine, ha-cluster puts etcd on every control-plane machine), so
# nothing else in CI evaluates a machine that has one of the two without the
# other. That is precisely where the certificate declarations and the
# `cluster.cairn.*` option declarations stop lining up.
#
# Evaluation-only, like ./consumer-services.nix and ./flake-module.nix: the
# breakage is a missing attribute at eval time, and booting two machines
# would prove nothing further.
{
  cairnModules,
  clan-core,
  nixpkgs,
  pkgs,
}:
let
  inherit (pkgs.stdenv.hostPlatform) system;

  clusterName = "split-topology";
  etcdIp = "10.10.0.31";
  cpIp = "10.10.0.11";
  vip = "10.10.0.10";

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
          apiserverPort = 6443;
          inherit vip clusterName;
        };
      };

      kubelet = mkModule "kubelet" // {
        roles.control-plane.machines.cp1.settings.ip = cpIp;
      };

      network = mkModule "network" // {
        roles.node.tags = [ "control-plane" ];
        roles.node.settings = { inherit vip clusterName; };
      };

      kubeconfig = mkModule "kubeconfig" // {
        roles.node.tags = [ "control-plane" ];
        roles.node.settings = { inherit vip clusterName; };
      };
    };

    machines.etcd1.nixpkgs.hostPlatform = system;
    machines.cp1.nixpkgs.hostPlatform = system;
  };

  etcd1 = consumer.config.nixosConfigurations.etcd1.config;
  cp1 = consumer.config.nixosConfigurations.cp1.config;

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
  };
in
pkgs.runCommand "cairn-split-topology" { } ''
  ${builtins.deepSeq probe ":"}
  touch "$out"
''
