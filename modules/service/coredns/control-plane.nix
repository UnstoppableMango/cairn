{
  config,
  lib,
  ...
}:
let
  cfg = config.cluster.cairn.coredns;
in
{
  options.cluster.cairn.coredns = {
    nodeNames = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      description = "Hostnames of control-plane nodes CoreDNS may be scheduled onto.";
    };

    manifests = lib.mkOption {
      type = lib.types.attrsOf lib.types.attrs;
      # nixpkgs computes these regardless of addonManager.enable, which we keep false.
      # Excludes bootstrapAddons (RBAC for kube-addon-manager, which never runs here).
      #
      # coredns's image is only seeded on control-plane nodes; with
      # imagePullPolicy = Never, the pod would fail to pull if scheduled onto
      # a worker node lacking it. Pin to control-plane nodes by hostname:
      # kubelet's NodeRestriction admission blocks self-applied
      # node-role.kubernetes.io/* labels, and inoculant has no node-labeling
      # feature yet, so kubernetes.io/hostname (set automatically) is the
      # only reliable selector available.
      default = lib.recursiveUpdate config.services.kubernetes.addonManager.addons {
        coredns-deploy.spec.template.spec = {
          affinity.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution.nodeSelectorTerms = [
            {
              matchExpressions = [
                {
                  key = "kubernetes.io/hostname";
                  operator = "In";
                  values = cfg.nodeNames;
                }
              ];
            }
          ];

          # nixpkgs' default toleration for "node-role.kubernetes.io/master" omits
          # operator/value, so it defaults to Equal against value "", which never
          # matches the master taint's value "true" (set by
          # services.kubernetes.kubelet.taints.master). Use Exists so it actually
          # tolerates the taint.
          #
          # nixpkgs also taints these nodes "unschedulable=true:NoSchedule"
          # whenever roles = [ "master" ] (services.kubernetes.kubelet.unschedulable
          # defaults to true for master-only nodes, mimicking kubeadm's "don't run
          # workloads on control-plane" convention). Since these are the only
          # nodes the image is seeded on, tolerate that too rather than making
          # them schedulable generally.
          tolerations = [
            {
              key = "node-role.kubernetes.io/master";
              operator = "Exists";
              effect = "NoSchedule";
            }
            {
              key = "unschedulable";
              operator = "Exists";
              effect = "NoSchedule";
            }
            {
              key = "CriticalAddonsOnly";
              operator = "Exists";
            }
          ];
        };
      };
      description = "CoreDNS manifests applied via inoculant.";
    };
  };

  config = {
    services.kubernetes.kubelet.seedDockerImages = [
      config.services.kubernetes.addons.dns.corednsImage
    ];

    services.kubernetes.inoculant = {
      enable = true;
      manifests = cfg.manifests;
    };
  };
}
