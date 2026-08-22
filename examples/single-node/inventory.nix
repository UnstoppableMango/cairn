{
  # Name of the flake input cairn's modules are resolved through. Consumer
  # flakes use the name they gave the input ("cairn"); cairn's own in-repo
  # examples use "self" (see modules/service/AGENTS.md).
  moduleInput ? "cairn",
  ip ? "10.10.0.11",
  vip ? ip,
  clusterName ? "single-node",
}:
{
  inventory.machines.node1 = {
    tags = [ "control-plane" ];
  };

  inventory.instances = {
    pki = {
      module.name = "@UnstoppableMango/pki";
      module.input = moduleInput;

      roles.node.tags.all = { };
    };

    etcd = {
      module.name = "@UnstoppableMango/etcd";
      module.input = moduleInput;

      roles.member.machines.node1.settings = { inherit ip clusterName; };
    };

    apiserver = {
      module.name = "@UnstoppableMango/apiserver";
      module.input = moduleInput;

      # No loadbalancer on a single node: bind the real apiserver on 6443
      # directly instead of the usual 6444-fronted-by-6443 split.
      roles.control-plane.machines.node1.settings = {
        inherit ip vip clusterName;
        apiserverPort = 6443;
      };
    };

    kubelet = {
      module.name = "@UnstoppableMango/kubelet";
      module.input = moduleInput;

      roles.control-plane.machines.node1.settings.ip = ip;
    };

    network = {
      module.name = "@UnstoppableMango/network";
      module.input = moduleInput;

      # `tags` is membership-only; clan never reads settings nested under a
      # tag (only role-wide `roles.<role>.settings` and per-machine
      # `roles.<role>.machines.<name>.settings` feed evalMachineSettings), so
      # the role-wide settings applying to every tag-matched machine go here.
      roles.node.tags = [ "all" ];
      roles.node.settings = { inherit vip clusterName; };
    };

    kubeconfig = {
      module.name = "@UnstoppableMango/kubeconfig";
      module.input = moduleInput;

      roles.node.tags = [ "all" ];
      roles.node.settings = { inherit vip clusterName; };
    };
  };
}
