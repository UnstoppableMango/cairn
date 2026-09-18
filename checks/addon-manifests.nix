# Evaluation-only coverage for the hand-authored addon manifests.
#
# The manifests reach a live cluster through inoculant, which renders them to
# JSON on the machine. Forcing that rendering here would mean IFD over clan
# vars paths that only exist after `clan vars generate`, so this calls the
# manifest sets directly with fixtures instead: enough to catch a typo, a
# missing RBAC rule, or a manifest that cannot be serialized, which is what
# the VM test cannot reach and the option-tree check does not force.
{ pkgs, lib }:
let
  metricsServer = import ../modules/service/metrics-server/manifests.nix {
    image = {
      imageName = "metrics-server";
      imageTag = "0.7.2";
    };
    nodeNames = [
      "cp1"
      "cp2"
    ];
    replicas = 2;
    kubeletCaFile = "/etc/cairn/ca.crt";
    metricResolution = "15s";
    extraArgs = [ "--v=2" ];
  };

  container = lib.head metricsServer.metrics-server-deployment.spec.template.spec.containers;

  hasArg = prefix: lib.any (a: lib.hasPrefix prefix a) container.args;

  expectations = [
    {
      msg = "metrics-server registers the Metrics API with the aggregation layer";
      cond =
        metricsServer.metrics-server-apiservice.metadata.name == "v1beta1.metrics.k8s.io"
        && metricsServer.metrics-server-apiservice.spec.service.name == "metrics-server";
    }
    {
      # Without the auth-delegator binding every request the apiserver proxies
      # is rejected, and without the auth-reader RoleBinding metrics-server
      # cannot authenticate the front proxy at all.
      msg = "metrics-server can delegate authn/authz to the apiserver";
      cond =
        metricsServer.metrics-server-auth-delegator.roleRef.name == "system:auth-delegator"
        &&
          metricsServer.metrics-server-auth-reader.roleRef.name
          == "extension-apiserver-authentication-reader";
    }
    {
      msg = "kubectl top works for non-admins via the aggregated view roles";
      cond =
        metricsServer.metrics-server-aggregated-reader.metadata.labels
          ? "rbac.authorization.k8s.io/aggregate-to-view";
    }
    {
      msg = "metrics-server may read the kubelet metrics endpoints it scrapes";
      cond = lib.any (
        r: r.resources == [ "nodes/metrics" ] && r.verbs == [ "get" ]
      ) metricsServer.metrics-server-cr.rules;
    }
    {
      # The kubelet serving cert's only SAN is the machine's advertise
      # address, so dropping either flag turns every scrape into a TLS
      # verification failure.
      msg = "kubelet scrapes verify against the cluster CA by address";
      cond =
        hasArg "--kubelet-certificate-authority=" && hasArg "--kubelet-preferred-address-types=InternalIP";
    }
    {
      msg = "the container's arguments and mounts agree on the CA path";
      cond = lib.any (m: m.mountPath == "/etc/cairn/ca.crt") container.volumeMounts;
    }
    {
      msg = "the image is the seeded one, never pulled";
      cond = container.image == "metrics-server:0.7.2" && container.imagePullPolicy == "Never";
    }
    {
      msg = "settings the option tree threads through reach the manifests";
      cond =
        let
          affinity = metricsServer.metrics-server-deployment.spec.template.spec.affinity;
          terms = affinity.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution.nodeSelectorTerms;
          hostnames = (lib.head (lib.head terms).matchExpressions).values;
        in
        metricsServer.metrics-server-deployment.spec.replicas == 2
        && lib.elem "--v=2" container.args
        &&
          hostnames == [
            "cp1"
            "cp2"
          ];
    }
  ];

  failures = map (e: e.msg) (lib.filter (e: !e.cond) expectations);
in
lib.throwIf (failures != [ ])
  "checks/addon-manifests.nix: the addon manifests no longer hold: ${lib.concatStringsSep "; " failures}"
  (
    pkgs.runCommand "cairn-addon-manifests" { } ''
      # Forces every manifest through the JSON serialization inoculant
      # renders them with on the machine.
      echo ${builtins.hashString "sha256" (builtins.toJSON metricsServer)} > /dev/null
      touch "$out"
    ''
  )
