# Seeded addon images run with `imagePullPolicy: Never`, so each seeding node advertises its tag and the Deployment requires it, letting a one-at-a-time control-plane redeploy avoid ErrImageNeverPull (#103).
{
  label = name: "cairn/${name}-image";

  # One term, so a node must match both expressions.
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
