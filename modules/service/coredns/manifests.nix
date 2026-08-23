{
  clusterIp,
  corefile,
  replicas,
  image,
  nodeNames,
}:
let
  ports = {
    dns = 10053;
    health = 10054;
    metrics = 10055;
  };

  labels = {
    k8s-app = "kube-dns";
  };
in
{
  coredns-sa = {
    apiVersion = "v1";
    kind = "ServiceAccount";
    metadata = {
      name = "coredns";
      namespace = "kube-system";
      inherit labels;
    };
  };

  coredns-cr = {
    apiVersion = "rbac.authorization.k8s.io/v1";
    kind = "ClusterRole";
    metadata = {
      name = "system:coredns";
      inherit labels;
    };
    rules = [
      {
        apiGroups = [ "" ];
        resources = [
          "endpoints"
          "services"
          "pods"
          "namespaces"
        ];
        verbs = [
          "list"
          "watch"
        ];
      }
      {
        apiGroups = [ "" ];
        resources = [ "nodes" ];
        verbs = [ "get" ];
      }
      {
        apiGroups = [ "discovery.k8s.io" ];
        resources = [ "endpointslices" ];
        verbs = [
          "list"
          "watch"
        ];
      }
    ];
  };

  coredns-crb = {
    apiVersion = "rbac.authorization.k8s.io/v1";
    kind = "ClusterRoleBinding";
    metadata = {
      name = "system:coredns";
      inherit labels;
    };
    roleRef = {
      apiGroup = "rbac.authorization.k8s.io";
      kind = "ClusterRole";
      name = "system:coredns";
    };
    subjects = [
      {
        kind = "ServiceAccount";
        name = "coredns";
        namespace = "kube-system";
      }
    ];
  };

  coredns-cm = {
    apiVersion = "v1";
    kind = "ConfigMap";
    metadata = {
      name = "coredns";
      namespace = "kube-system";
      inherit labels;
    };
    data.Corefile = corefile;
  };

  coredns-deploy = {
    apiVersion = "apps/v1";
    kind = "Deployment";
    metadata = {
      name = "coredns";
      namespace = "kube-system";
      inherit labels;
    };
    spec = {
      inherit replicas;
      selector.matchLabels = labels;
      strategy = {
        type = "RollingUpdate";
        rollingUpdate.maxUnavailable = 1;
      };
      template = {
        metadata.labels = labels;
        spec = {
          serviceAccountName = "coredns";
          dnsPolicy = "Default";
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
          # nixpkgs' default toleration for "node-role.kubernetes.io/master" omits
          # operator/value, so it defaults to Equal against value "", which never
          # matches the master taint's value "true" (set by
          # services.kubernetes.kubelet.taints.master). Use Exists so it actually
          # tolerates the taint. Also tolerate the "unschedulable" taint nixpkgs
          # applies to master-only nodes (services.kubernetes.kubelet.unschedulable
          # defaults to true there), since these control-plane nodes are the only
          # ones the image is seeded on.
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
              name = "coredns";
              image = "${image.imageName}:${image.imageTag}";
              imagePullPolicy = "Never";
              args = [
                "-conf"
                "/etc/coredns/Corefile"
              ];
              ports = [
                {
                  name = "dns";
                  containerPort = ports.dns;
                  protocol = "UDP";
                }
                {
                  name = "dns-tcp";
                  containerPort = ports.dns;
                  protocol = "TCP";
                }
                {
                  name = "metrics";
                  containerPort = ports.metrics;
                  protocol = "TCP";
                }
              ];
              livenessProbe = {
                httpGet = {
                  path = "/health";
                  port = ports.health;
                  scheme = "HTTP";
                };
                initialDelaySeconds = 60;
                timeoutSeconds = 5;
                successThreshold = 1;
                failureThreshold = 5;
              };
              # Without this, kubelet marks the pod Ready as soon as the
              # container starts, before CoreDNS finishes waiting on its
              # Kubernetes API cache sync and actually binds :10053 — callers
              # racing in against a "ready" replica get connection refused.
              readinessProbe = {
                httpGet = {
                  path = "/health";
                  port = ports.health;
                  scheme = "HTTP";
                };
                timeoutSeconds = 5;
                successThreshold = 1;
                failureThreshold = 3;
                periodSeconds = 5;
              };
              resources = {
                requests = {
                  cpu = "100m";
                  memory = "70Mi";
                };
                limits.memory = "170Mi";
              };
              securityContext = {
                allowPrivilegeEscalation = false;
                readOnlyRootFilesystem = true;
                capabilities = {
                  add = [ "NET_BIND_SERVICE" ];
                  drop = [ "all" ];
                };
              };
              volumeMounts = [
                {
                  name = "config-volume";
                  mountPath = "/etc/coredns";
                  readOnly = true;
                }
              ];
            }
          ];
          volumes = [
            {
              name = "config-volume";
              configMap = {
                name = "coredns";
                items = [
                  {
                    key = "Corefile";
                    path = "Corefile";
                  }
                ];
              };
            }
          ];
        };
      };
    };
  };

  coredns-svc = {
    apiVersion = "v1";
    kind = "Service";
    metadata = {
      name = "kube-dns";
      namespace = "kube-system";
      inherit labels;
      annotations = {
        "prometheus.io/scrape" = "true";
        "prometheus.io/port" = toString ports.metrics;
      };
    };
    spec = {
      clusterIP = clusterIp;
      selector = labels;
      ports = [
        {
          name = "dns";
          port = 53;
          targetPort = ports.dns;
          protocol = "UDP";
        }
        {
          name = "dns-tcp";
          port = 53;
          targetPort = ports.dns;
          protocol = "TCP";
        }
      ];
    };
  };
}
