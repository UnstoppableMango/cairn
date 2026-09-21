# The `cairn.clusters.<name>` option tree: a whole Kubernetes cluster described
# in one place, lowered to clan inventory instances and per-machine NixOS
# config by ./lower.nix.
#
# The surface is deliberately wide. Every setting any role `interface` under
# modules/service/ accepts is reachable here, and so are the cairn NixOS
# options no inventory setting reaches at all (`cluster.cairn.apiServerPort`,
# `etcd.initialClusterState`, the `coredns.*` knobs, the pki `override`
# escape hatches). Where a service grows an option, this file and ./lower.nix
# grow with it; `settings` / `extraModules` / `nixos` / `extraInstances` are
# the escape hatches for anything not yet modelled.
{ lib }:
let
  inherit (lib)
    literalMD
    mkOption
    types
    ;

  # enable/settings/extraModules, identical for every service.
  common = svc: {
    enable = mkOption {
      type = types.bool;
      default = true;
      description = "Whether to deploy the ${svc} service to this cluster.";
    };

    settings = mkOption {
      type = types.attrsOf types.anything;
      default = { };
      description = ''
        Extra inventory settings merged over the ones cairn computes for
        every ${svc} role assignment. These win on conflict, so this is the
        escape hatch for a ${svc} setting this module doesn't model yet.
      '';
    };

    extraModules = mkOption {
      type = types.listOf types.deferredModule;
      default = [ ];
      description = "Extra NixOS modules added to every ${svc} role assignment.";
    };
  };

  mkMachinesOption =
    {
      default,
      defaultText,
      description,
    }:
    mkOption {
      inherit default description;
      type = types.listOf types.str;
      defaultText = literalMD defaultText;
    };

  overrideType =
    subject:
    types.nullOr (
      types.submodule {
        options = {
          crt = mkOption {
            type = types.str;
            description = "Filesystem path to a pre-existing ${subject} certificate (PEM).";
          };
          key = mkOption {
            type = types.str;
            description = "Filesystem path to a pre-existing ${subject} private key (PEM).";
          };
        };
      }
    );

  machineModule =
    { name, ... }:
    {
      options = {
        role = mkOption {
          type = types.enum [
            "control-plane"
            "worker"
          ];
          description = ''
            What this machine does in the cluster. Drives which services it is
            assigned by default, the tag it carries in the inventory, and its
            default `nodeLabels`.
          '';
        };

        ip = mkOption {
          type = types.str;
          description = "IP address this machine advertises to the rest of the cluster.";
        };

        tags = mkOption {
          type = types.listOf types.str;
          default = [ ];
          description = ''
            Extra inventory tags for this machine, on top of the `role` tag it
            always gets. Useful for assigning your own non-cairn services.
          '';
        };

        nodeLabels = mkOption {
          type = types.attrsOf types.str;
          default = { };
          example = {
            "example.com/ci-runner" = "true";
          };
          description = ''
            Extra labels inoculant applies to this node, on top of the
            `node-role.kubernetes.io/<role>` label it always gets. inoculant
            applies these because kubelet is forbidden from setting
            `node-role.kubernetes.io/*` on itself.

            An entry here for the role label overrides it.
          '';
        };

        keepalivedPriority = mkOption {
          type = types.nullOr types.int;
          default = null;
          description = ''
            VRRP priority for this machine, highest wins the VIP. Stagger these
            across control-plane machines so one of them holds the VIP by
            default. `null` leaves the loadbalancer service's own default (100).
          '';
        };

        kubernetesVersion = mkOption {
          type = types.nullOr types.str;
          default = null;
          example = "1.36";
          description = ''
            kubepkgs minor this machine runs, overriding the cluster's
            `versions.kubernetes`. Version skew across machines must respect
            Kubernetes' policy (see docs/UPGRADES.md); the lowering asserts
            it where both sides are pinned.
          '';
        };

        maxPods = mkOption {
          type = types.nullOr types.ints.positive;
          default = null;
          example = 250;
          description = ''
            Pods this machine's kubelet will admit, overriding the cluster's
            `services.kubelet.maxPods`. `null` takes the cluster value.

            Size it against the machine, and against the node's podCIDR: the
            default /24 per node leaves 254 addresses.
          '';
        };

        systemReserved = mkOption {
          type = types.nullOr (types.attrsOf types.str);
          default = null;
          example = {
            cpu = "2";
            memory = "2Gi";
          };
          description = ''
            Resources this machine withholds from pods for the kernel, the
            container runtime, and anything it runs outside Kubernetes,
            overriding the cluster's `services.kubelet.systemReserved`.
            `null` takes the cluster value.

            Set it per machine where one node carries something the others
            do not, a storage daemon or a build agent. A cluster-wide figure
            sized for that machine strands the same memory on every other
            one.
          '';
        };

        kubeReserved = mkOption {
          type = types.nullOr (types.attrsOf types.str);
          default = null;
          example = {
            cpu = "1";
            memory = "1Gi";
          };
          description = ''
            Resources this machine withholds for the kubelet and container
            runtime, overriding the cluster's `services.kubelet.kubeReserved`.
            `null` takes the cluster value.
          '';
        };

        evictionHard = mkOption {
          type = types.nullOr (types.attrsOf types.str);
          default = null;
          example = {
            "memory.available" = "1Gi";
          };
          description = ''
            Hard eviction thresholds for this machine, overriding the
            cluster's `services.kubelet.evictionHard`. `null` takes the
            cluster value.
          '';
        };

        schedulable = mkOption {
          type = types.bool;
          default = false;
          description = ''
            Also give this control-plane machine the NixOS `node` role, so pods
            can schedule onto it. nixpkgs' kubernetes module taints a
            master-only machine unschedulable; set this on a cluster with no
            separate worker machines. Has no effect on a `worker` machine,
            which is a node already.
          '';
        };

        nixos = mkOption {
          type = types.deferredModule;
          default = { };
          description = ''
            NixOS configuration for this machine alone, merged into
            `clan.machines.${name}`. This is where the machine's hardware
            config, `nixpkgs.hostPlatform`, filesystems and bootloader go.
          '';
        };
      };
    };

  servicesModule =
    cluster:
    { config, ... }:
    let
      machineNames = lib.attrNames cluster.machines;
      withRole = role: lib.attrNames (lib.filterAttrs (_: m: m.role == role) cluster.machines);
      controlPlane = withRole "control-plane";
      workers = withRole "worker";
    in
    {
      options = {
        pki = {
          inherit (common "pki") enable settings extraModules;

          machines = mkMachinesOption {
            default = machineNames;
            defaultText = "every machine in the cluster";
            description = "Machines that get cluster PKI. Anything that touches a certificate, directly or indirectly, belongs here.";
          };

          generatorPrefix = mkOption {
            type = types.str;
            default = "cairn";
            description = ''
              Prefix for clan var generator names (`<prefix>-ca`,
              `<prefix>-<cert>`). Change it only to line up with generator
              names an existing cluster already has on disk; it is cluster-wide
              and every machine must agree.
            '';
          };

          certValidityDays = mkOption {
            type = types.int;
            default = 3650;
            description = "Validity period for generated certificates, in days.";
          };

          ca.override = mkOption {
            type = overrideType "CA";
            default = null;
            description = ''
              Bring-your-own CA material, copied in instead of prompting for it
              at `clan vars generate` time. Paths are resolved on the invoking
              machine and never enter the Nix store.
            '';
          };

          certs = mkOption {
            type = types.attrsOf types.anything;
            default = { };
            description = ''
              Additional `cluster.cairn.pki.certs.<name>` definitions applied to
              every pki machine, for certificates cairn's own services don't
              declare. Also where a per-certificate `override` goes.
            '';
          };
        };

        etcd = {
          inherit (common "etcd") enable settings extraModules;

          machines = mkMachinesOption {
            default = controlPlane;
            defaultText = "every control-plane machine";
            description = "Machines forming the etcd quorum.";
          };

          initialClusterState = mkOption {
            type = types.enum [
              "new"
              "existing"
            ];
            default = "new";
            description = ''
              etcd's initial cluster state. Leave at `new` when bringing the
              quorum up together; `existing` when replacing a member or
              restoring into a live cluster.
            '';
          };
        };

        apiserver = {
          inherit (common "apiserver") enable settings extraModules;

          machines = mkMachinesOption {
            default = controlPlane;
            defaultText = "every control-plane machine";
            description = "Machines running kube-apiserver, kube-controller-manager and kube-scheduler.";
          };

          port = mkOption {
            type = types.port;
            default = if config.loadbalancer.enable then 6444 else cluster.apiServerPort;
            defaultText = literalMD "`6444` with the loadbalancer enabled, otherwise `apiServerPort`";
            description = ''
              Port the local apiserver binds to. With the loadbalancer enabled
              this sits behind HAProxy on the VIP, so it differs from the
              cluster's `apiServerPort`; without one the apiserver *is* what
              clients reach, so the two must match.
            '';
          };

          serviceClusterIP = mkOption {
            type = types.str;
            default = "10.0.0.1";
            description = "First IP of the service CIDR; included in the apiserver's certificate SANs.";
          };

          allowPrivileged = mkOption {
            type = types.bool;
            default = true;
            description = ''
              Whether to allow pods requesting `securityContext.privileged`.
              CSI node plugins and Ceph OSD daemons hardcode it, and the
              apiserver rejects them at admission without it.
            '';
          };
        };

        kubelet = {
          inherit (common "kubelet") enable settings extraModules;

          machines = mkMachinesOption {
            default = machineNames;
            defaultText = "every machine";
            description = ''
              Machines running a kubelet, and so appearing as Kubernetes
              nodes. Whether pods schedule onto one is `machines.<name>.schedulable`,
              which a `worker` machine has by definition.
            '';
          };

          rootDir = mkOption {
            type = types.path;
            default = "/var/lib/kubelet";
            description = ''
              kubelet's `--root-dir`. The upstream default, and the path CSI
              drivers hardcode as `hostPath` mounts. nixpkgs points it at
              `services.kubernetes.dataDir` instead, which no CSI driver
              expects.
            '';
          };

          maxPods = mkOption {
            type = types.ints.positive;
            default = 110;
            description = ''
              Pods a kubelet will admit, for machines that do not set
              `machines.<name>.maxPods`. kubelet's own default is 110.
            '';
          };

          systemReserved = mkOption {
            type = types.attrsOf types.str;
            default = { };
            example = {
              cpu = "1";
              memory = "1Gi";
            };
            description = ''
              Resources withheld from pods for the kernel, the container
              runtime and the rest of the host, for machines that do not set
              `machines.<name>.systemReserved`.

              Allocatable is capacity minus this, `kubeReserved` and the
              `evictionHard` memory threshold, and the scheduler places
              against allocatable. Empty by default, which is kubelet's own
              behaviour and hands the scheduler nearly the whole machine.
            '';
          };

          kubeReserved = mkOption {
            type = types.attrsOf types.str;
            default = { };
            example = {
              cpu = "1";
              memory = "1Gi";
            };
            description = ''
              Resources withheld for the kubelet and container runtime, for
              machines that do not set `machines.<name>.kubeReserved`.
            '';
          };

          evictionHard = mkOption {
            type = types.attrsOf types.str;
            default = { };
            example = {
              "memory.available" = "1Gi";
            };
            description = ''
              Hard eviction thresholds, for machines that do not set
              `machines.<name>.evictionHard`. The memory threshold also
              subtracts from allocatable.
            '';
          };
        };

        loadbalancer = {
          inherit (common "loadbalancer") settings extraModules;

          enable = mkOption {
            type = types.bool;
            default = false;
            description = ''
              Front the apiserver cluster with a keepalived-managed VIP and
              HAProxy. Needed for an HA control plane; a single-machine cluster
              can point `vip` straight at the machine's own IP instead.
            '';
          };

          machines = mkMachinesOption {
            default = controlPlane;
            defaultText = "every control-plane machine";
            description = "Machines running keepalived and HAProxy.";
          };

          interface = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = "Network interface keepalived runs VRRP on. Required when the loadbalancer is enabled.";
          };

          virtualRouterId = mkOption {
            type = types.int;
            default = 50;
            description = "Keepalived VRRP virtual router ID (1-255), unique per subnet.";
          };

          # Same declaration as the service interface, so defaults and types
          # cannot drift between the two surfaces.
          inherit (import ../../modules/service/loadbalancer/options.nix { inherit lib; }) healthCheck;
        };

        network = {
          inherit (common "network") enable settings extraModules;

          machines = mkMachinesOption {
            default = machineNames;
            defaultText = "every machine in the cluster";
            description = "Machines running Flannel pod networking.";
          };
        };

        kubeconfig = {
          inherit (common "kubeconfig") enable settings extraModules;

          machines = mkMachinesOption {
            default = machineNames;
            defaultText = "every machine in the cluster";
            description = "Machines that get an admin kubeconfig and kubectl.";
          };
        };

        inoculant = {
          inherit (common "inoculant") enable settings extraModules;

          machines = mkMachinesOption {
            default = machineNames;
            defaultText = "every machine in the cluster";
            description = ''
              Machines running inoculant. Every machine wanting node labels
              needs it, not just the ones bootstrapping manifests. Each of
              these also needs the kubeconfig service, whose admin cert
              inoculant reuses.
            '';
          };
        };

        coredns = {
          inherit (common "coredns") enable settings extraModules;

          machines = mkMachinesOption {
            default = controlPlane;
            defaultText = "every control-plane machine";
            description = "Machines CoreDNS may be scheduled onto, and from which its manifests are bootstrapped.";
          };

          nodeNames = mkOption {
            type = types.nullOr (types.listOf types.str);
            default = null;
            description = ''
              Machines CoreDNS pods may be scheduled onto, as node affinity in
              the generated Deployment. `null` uses `machines`, which is right
              while the machines bootstrapping the manifests are the ones
              running kubelets. Name the nodes outright when they are not.
            '';
          };

          serviceClusterIpRange = mkOption {
            type = types.nullOr types.str;
            default = null;
            example = "10.96.0.0/12";
            description = ''
              Service CIDR `clusterIp` is derived from. `null` keeps the
              service's own default of `10.0.0.0/24`, which is also nixpkgs'
              apiserver default. Set it alongside the apiserver's own range
              rather than on its own.
            '';
          };

          clusterIp = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = ''
              ClusterIP for the kube-dns Service. `null` keeps the service's own
              derived default, the `.254` address of the service CIDR.
            '';
          };

          clusterDomain = mkOption {
            type = types.str;
            default = "cluster.local";
            description = "Cluster domain CoreDNS serves.";
          };

          replicas = mkOption {
            type = types.int;
            default = 2;
            description = "Number of CoreDNS pod replicas.";
          };

          corefile = mkOption {
            type = types.nullOr types.lines;
            default = null;
            description = "Corefile contents. `null` keeps the service's own default Corefile.";
          };

          image = mkOption {
            type = types.nullOr types.package;
            default = null;
            description = "Docker image seeded for the CoreDNS container. `null` keeps the service's own nixpkgs-built image.";
          };
        };

        metrics-server = {
          inherit (common "metrics-server") settings extraModules;

          enable = mkOption {
            type = types.bool;
            default = false;
            description = "Bootstrap metrics-server manifests via inoculant, serving the Metrics API.";
          };

          machines = mkMachinesOption {
            default = controlPlane;
            defaultText = "every control-plane machine";
            description = "Machines metrics-server may be scheduled onto, and from which its manifests are bootstrapped.";
          };

          nodeNames = mkOption {
            type = types.nullOr (types.listOf types.str);
            default = null;
            description = ''
              Machines metrics-server pods may be scheduled onto, as node
              affinity in the generated Deployment. `null` uses `machines`.
              These must run a kubelet and have the pki service assigned,
              since the pod mounts the cluster CA off the node.
            '';
          };

          replicas = mkOption {
            type = types.int;
            default = 1;
            description = "Number of metrics-server pod replicas.";
          };

          metricResolution = mkOption {
            type = types.str;
            default = "15s";
            description = "How often metrics-server scrapes kubelets. Must stay below the 60s window the Metrics API serves.";
          };

          extraArgs = mkOption {
            type = types.listOf types.str;
            default = [ ];
            example = [ "--kubelet-insecure-tls" ];
            description = "Extra arguments appended to the metrics-server container's command line.";
          };

          package = mkOption {
            type = types.nullOr types.package;
            default = null;
            description = "metrics-server build the image is made from. `null` takes the cluster's pinned kubepkgs minor, or kubepkgs' newest when nothing is pinned.";
          };

          image = mkOption {
            type = types.nullOr types.package;
            default = null;
            description = "Docker image seeded for the metrics-server container. `null` keeps the service's own image, built from `package`.";
          };
        };

        flux = {
          inherit (common "flux") settings extraModules;

          enable = mkOption {
            type = types.bool;
            default = false;
            description = "Bootstrap Flux (GitOps) manifests via inoculant, pointed at `url`.";
          };

          machines = mkMachinesOption {
            default = controlPlane;
            defaultText = "every control-plane machine";
            description = "Machines that bootstrap the Flux manifests.";
          };

          url = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = "Git URL of the GitOps repository Flux syncs from. Required when flux is enabled.";
          };

          branch = mkOption {
            type = types.str;
            default = "main";
            description = "Branch of the GitOps repository to track.";
          };

          path = mkOption {
            type = types.str;
            default = "./clusters/cairn";
            description = "Path within the GitOps repository that Flux's root Kustomization targets.";
          };
        };
      };
    };

  clusterModule =
    { name, config, ... }:
    {
      options = {
        enable = mkOption {
          type = types.bool;
          default = true;
          description = "Whether to deploy this cluster. Set to false to keep the definition around without producing any inventory.";
        };

        clusterName = mkOption {
          type = types.str;
          default = name;
          defaultText = literalMD "the attribute name";
          description = "Kubernetes cluster name, used in TLS subject names and cluster identifiers.";
        };

        moduleInput = mkOption {
          type = types.str;
          default = "cairn";
          description = ''
            Name of the flake input cairn's modules resolve through, i.e. the
            name you gave the cairn input. Only cairn's own in-repo examples
            use `"self"`.
          '';
        };

        instancePrefix = mkOption {
          type = types.nullOr types.str;
          default = null;
          defaultText = literalMD "empty for a lone cluster, `\"<name>-\"` when several are declared";
          description = ''
            Prefix for the generated `inventory.instances` names. Two clusters
            in one clan would otherwise both want to define an instance called
            `etcd`, so declaring more than one turns prefixing on
            automatically. Set this explicitly to pin the names.
          '';
        };

        vip = mkOption {
          type = types.str;
          description = ''
            Address clients and nodes reach the apiserver at. With the
            loadbalancer enabled this is the floating VIP keepalived manages;
            without one, point it at the single apiserver machine's own IP.
          '';
        };

        apiServerPort = mkOption {
          type = types.port;
          default = 6443;
          description = "Port the apiserver is reached on at the VIP; what the loadbalancer's HAProxy binds.";
        };

        machines = mkOption {
          type = types.attrsOf (types.submodule machineModule);
          default = { };
          description = "Machines making up this cluster, keyed by their inventory (and host) name.";
        };

        services = mkOption {
          type = types.submodule (servicesModule config);
          default = { };
          description = "Per-service configuration. Each service is assigned a sensible set of machines from their roles; override the lists to deviate.";
        };

        nixos = mkOption {
          type = types.deferredModule;
          default = { };
          description = "NixOS configuration merged into every machine in this cluster.";
        };

        versions = {
          kubernetes = mkOption {
            type = types.nullOr types.str;
            default = null;
            example = "1.36";
            description = ''
              Kubernetes minor every machine runs, from kubepkgs' per-minor
              package sets. `null` follows nixpkgs' `pkgs.kubernetes`, coupling
              the cluster version to the nixpkgs pin. Per-machine
              `machines.<name>.kubernetesVersion` overrides this. See
              docs/UPGRADES.md for the upgrade procedure this drives.
            '';
          };

          kubernetesPackage = mkOption {
            type = types.nullOr types.package;
            default = null;
            description = ''
              Fully custom combined Kubernetes package (everything
              `services.kubernetes.package` expects, including a `pause`
              passthru), set on every machine. Mutually exclusive with
              `versions.kubernetes` and per-machine `kubernetesVersion`.
            '';
          };

          etcdPackage = mkOption {
            type = types.nullOr types.package;
            default = null;
            description = ''
              etcd server for the cluster's members, overriding the etcd
              that `versions.kubernetes` selects from kubepkgs. `null` takes
              the pinned minor's etcd, or nixpkgs' `pkgs.etcd` when no minor
              is pinned.
            '';
          };
        };

        requireExplicitUpdate = mkOption {
          type = types.bool;
          default = true;
          description = ''
            Exclude this cluster's machines from a bulk `clan machines update`,
            which deploys every machine in parallel and so restarts every etcd
            member and apiserver at once. With this set, machines only update
            when named explicitly, one at a time.
          '';
        };

        extraInstances = mkOption {
          type = types.attrsOf types.anything;
          default = { };
          description = ''
            Raw `inventory.instances` entries spliced in alongside the
            generated ones, for services this module doesn't model (including
            non-cairn ones). Names are used verbatim, without `instancePrefix`.
          '';
        };
      };
    };
in
{
  clusters = mkOption {
    type = types.attrsOf (types.submodule clusterModule);
    default = { };
    description = ''
      Kubernetes clusters to deploy with cairn. Each one lowers to a set of
      clan inventory instances plus the NixOS configuration its machines need.
    '';
  };
}
