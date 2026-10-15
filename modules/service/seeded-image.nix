# Addons whose images are seeded onto nodes rather than pulled (coredns,
# metrics-server) run with `imagePullPolicy: Never`, so a pod can only start
# where that exact tag was seeded. Each seeding node advertises the tag under
# `label name`, and the Deployment requires it in its node affinity. While
# control-plane machines are redeployed one at a time, new pods then land only
# on nodes that already have the new image instead of failing with
# ErrImageNeverPull on the rest (#103).
{
  label = name: "cairn/${name}-image";

  # The node affinity term pinning pods to `nodeNames` that have seeded
  # `image`. Both expressions sit in one term, so a node must match both.
  affinity = name: image: nodeNames: {
    nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution.nodeSelectorTerms = [
      {
        matchExpressions = [
          {
            key = "kubernetes.io/hostname";
            operator = "In";
            values = nodeNames;
          }
          {
            key = "cairn/${name}-image";
            operator = "In";
            values = [ image.imageTag ];
          }
        ];
      }
    ];
  };
}
