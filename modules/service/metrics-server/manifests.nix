{
  image,
  nodeNames,
  replicas,
  kubeletCaFile,
  metricResolution,
  extraArgs,
}:
let
  ports = import ./ports.nix;

  labels = {
    k8s-app = "metrics-server";
  };
in
{
  metrics-server-sa = {
    apiVersion = "v1";
    kind = "ServiceAccount";
    metadata = {
      name = "metrics-server";
      namespace = "kube-system";
      inherit labels;
    };
  };

  # Aggregated into the default view/edit/admin roles by label, which is how
  # `kubectl top` works for a user who is not cluster-admin.
  metrics-server-aggregated-reader = {
    apiVersion = "rbac.authorization.k8s.io/v1";
    kind = "ClusterRole";
    metadata = {
      name = "system:aggregated-metrics-reader";
      labels = labels // {
        "rbac.authorization.k8s.io/aggregate-to-admin" = "true";
        "rbac.authorization.k8s.io/aggregate-to-edit" = "true";
        "rbac.authorization.k8s.io/aggregate-to-view" = "true";
      };
    };
    rules = [
      {
        apiGroups = [ "metrics.k8s.io" ];
        resources = [
          "pods"
          "nodes"
        ];
        verbs = [
          "get"
          "list"
          "watch"
        ];
      }
    ];
  };

  metrics-server-cr = {
    apiVersion = "rbac.authorization.k8s.io/v1";
    kind = "ClusterRole";
    metadata = {
      name = "system:metrics-server";
      inherit labels;
    };
    rules = [
      {
        apiGroups = [ "" ];
        resources = [ "nodes/metrics" ];
        verbs = [ "get" ];
      }
      {
        apiGroups = [ "" ];
        resources = [
          "pods"
          "nodes"
          "namespaces"
          "configmaps"
        ];
        verbs = [
          "get"
          "list"
          "watch"
        ];
      }
    ];
  };

  metrics-server-crb = {
    apiVersion = "rbac.authorization.k8s.io/v1";
    kind = "ClusterRoleBinding";
    metadata = {
      name = "system:metrics-server";
      inherit labels;
    };
    roleRef = {
      apiGroup = "rbac.authorization.k8s.io";
      kind = "ClusterRole";
      name = "system:metrics-server";
    };
    subjects = [
      {
        kind = "ServiceAccount";
        name = "metrics-server";
        namespace = "kube-system";
      }
    ];
  };

  # Lets the apiserver delegate authn/authz for requests it proxies to the
  # aggregated API.
  metrics-server-auth-delegator = {
    apiVersion = "rbac.authorization.k8s.io/v1";
    kind = "ClusterRoleBinding";
    metadata = {
      name = "metrics-server:system:auth-delegator";
      inherit labels;
    };
    roleRef = {
      apiGroup = "rbac.authorization.k8s.io";
      kind = "ClusterRole";
      name = "system:auth-delegator";
    };
    subjects = [
      {
        kind = "ServiceAccount";
        name = "metrics-server";
        namespace = "kube-system";
      }
    ];
  };

  # Reads the requestheader client CA the apiserver publishes, so
  # metrics-server can authenticate the front proxy.
  metrics-server-auth-reader = {
    apiVersion = "rbac.authorization.k8s.io/v1";
    kind = "RoleBinding";
    metadata = {
      name = "metrics-server-auth-reader";
      namespace = "kube-system";
      inherit labels;
    };
    roleRef = {
      apiGroup = "rbac.authorization.k8s.io";
      kind = "Role";
      name = "extension-apiserver-authentication-reader";
    };
    subjects = [
      {
        kind = "ServiceAccount";
        name = "metrics-server";
        namespace = "kube-system";
      }
    ];
  };

  metrics-server-deployment = {
    apiVersion = "apps/v1";
    kind = "Deployment";
    metadata = {
      name = "metrics-server";
      namespace = "kube-system";
      inherit labels;
    };
    spec = {
      inherit replicas;
      selector.matchLabels = labels;
      strategy = {
        type = "RollingUpdate";
        rollingUpdate.maxUnavailable = 0;
      };
      template = {
        metadata.labels = labels;
        spec = {
          serviceAccountName = "metrics-server";
          priorityClassName = "system-cluster-critical";
          # Same node-pinning rationale as coredns: the image is seeded onto
          # these machines only, so the pod has to land on one of them.
          affinity.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution.nodeSelectorTerms = [
            {
              matchExpressions = [
                {
                  key = "kubernetes.io/hostname";
                  operator = "In";
                  values = nodeNames;
                }
              ];
            }
          ];
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
          containers = [
            {
              name = "metrics-server";
              image = "${image.imageName}:${image.imageTag}";
              imagePullPolicy = "Never";
              args = [
                "--cert-dir=/tmp"
                "--secure-port=${toString ports.secure}"
                # The kubelet serving cert's only SAN is the machine's
                # advertise address, so scraping by the node's Hostname
                # address would fail verification.
                "--kubelet-preferred-address-types=InternalIP"
                "--kubelet-use-node-status-port"
                "--kubelet-certificate-authority=${kubeletCaFile}"
                "--metric-resolution=${metricResolution}"
              ]
              ++ extraArgs;
              ports = [
                {
                  name = "https";
                  containerPort = ports.secure;
                  protocol = "TCP";
                }
              ];
              livenessProbe = {
                httpGet = {
                  path = "/livez";
                  port = "https";
                  scheme = "HTTPS";
                };
                periodSeconds = 10;
                failureThreshold = 3;
              };
              readinessProbe = {
                httpGet = {
                  path = "/readyz";
                  port = "https";
                  scheme = "HTTPS";
                };
                initialDelaySeconds = 20;
                periodSeconds = 10;
                failureThreshold = 3;
              };
              securityContext = {
                allowPrivilegeEscalation = false;
                readOnlyRootFilesystem = true;
                runAsNonRoot = true;
                runAsUser = 1000;
                capabilities.drop = [ "ALL" ];
              };
              volumeMounts = [
                {
                  name = "tmp-dir";
                  mountPath = "/tmp";
                }
                {
                  name = "kubelet-ca";
                  mountPath = kubeletCaFile;
                  readOnly = true;
                }
              ];
            }
          ];
          volumes = [
            {
              name = "tmp-dir";
              emptyDir = { };
            }
            # The CA is public, and mounting the file the machine already has
            # avoids reading it at evaluation time, when clan's vars
            # generators may not have run yet.
            {
              name = "kubelet-ca";
              hostPath = {
                path = kubeletCaFile;
                type = "File";
              };
            }
          ];
        };
      };
    };
  };

  metrics-server-svc = {
    apiVersion = "v1";
    kind = "Service";
    metadata = {
      name = "metrics-server";
      namespace = "kube-system";
      inherit labels;
    };
    spec = {
      selector = labels;
      ports = [
        {
          name = "https";
          port = 443;
          targetPort = "https";
          protocol = "TCP";
        }
      ];
    };
  };

  # metrics-server serves on a self-signed cert it generates into --cert-dir,
  # which is why the apiserver skips verification on this hop. The hop is
  # authenticated in the other direction, by the front-proxy client cert the
  # apiserver presents.
  metrics-server-apiservice = {
    apiVersion = "apiregistration.k8s.io/v1";
    kind = "APIService";
    metadata = {
      name = "v1beta1.metrics.k8s.io";
      inherit labels;
    };
    spec = {
      group = "metrics.k8s.io";
      version = "v1beta1";
      groupPriorityMinimum = 100;
      versionPriority = 100;
      insecureSkipTLSVerify = true;
      service = {
        name = "metrics-server";
        namespace = "kube-system";
        port = 443;
      };
    };
  };
}
