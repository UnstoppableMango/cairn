{
  cairnModules,
  globset,
}:
# Whether pods can run straight off the node's nix store, through
# nix-snapshotter, and build through the node's nix-daemon, on the same
# one-node cluster the single-node-cluster test boots. It settles the open
# questions before any real node adopts this: a user-namespaced pod
# (hostUsers: false) on a nix-snapshotter image, since nix-snapshotter does
# not advertise containerd's id-remapping capability; a sandboxed build from
# that pod through the node daemon; and registry images, here the seeded
# addon images, still running with nix-snapshotter as the snapshotter.
let
  base = import ../vm/default.nix { inherit cairnModules; };

  socket = "/run/nix-snapshotter/nix-snapshotter.sock";
in
base
// {
  name = "nix-snapshotter";

  nodes.node1 =
    { lib, pkgs, ... }:
    let
      # nixpkgs' `nix-snapshotter.buildImage` passthru calls upstream's
      # package.nix without the `globset` argument it requires, so it fails
      # to evaluate. Call that package.nix here with it.
      nix-snapshotter = pkgs.callPackage "${pkgs.nix-snapshotter.src}/package.nix" {
        inherit globset;
      };

      # Resolved by nix: the image is a store path whose layers name store
      # paths, which nix-snapshotter bind-mounts from the node's store rather
      # than unpacking.
      image = nix-snapshotter.buildImage {
        name = "store-probe";
        resolvedByNix = true;
        copyToRoot = pkgs.buildEnv {
          name = "store-probe-root";
          paths = [
            pkgs.busybox
            pkgs.nix
          ];
          pathsToLink = [ "/bin" ];
        };
        config = {
          entrypoint = [
            "/bin/sleep"
            "3600"
          ];
          env = [ "PATH=/bin" ];
        };
      };

      pod =
        name: spec:
        pkgs.writeText "${name}.json" (
          builtins.toJSON {
            apiVersion = "v1";
            kind = "Pod";
            metadata = { inherit name; };
            spec = {
              restartPolicy = "Never";
              containers = [
                (
                  {
                    name = "probe";
                    image = "nix:0${image}";
                    imagePullPolicy = "IfNotPresent";
                  }
                  // (spec.container or { })
                )
              ];
            }
            // removeAttrs spec [ "container" ];
          }
        );

      # The node's whole store, read-only, so a path the daemon builds is
      # visible to the pod, and the daemon's socket. The image has no /tmp,
      # which kubectl cp and nix's cache need.
      nodeStore = {
        volumes = [
          {
            name = "tmp";
            emptyDir = { };
          }
          {
            name = "nix-store";
            hostPath = {
              path = "/nix/store";
              type = "Directory";
            };
          }
          {
            name = "nix-daemon";
            hostPath = {
              path = "/nix/var/nix/daemon-socket";
              type = "Directory";
            };
          }
        ];
        container = {
          env = [
            {
              name = "NIX_REMOTE";
              value = "daemon";
            }
            {
              name = "HOME";
              value = "/tmp";
            }
          ];
          volumeMounts = [
            {
              name = "tmp";
              mountPath = "/tmp";
            }
            {
              name = "nix-store";
              mountPath = "/nix/store";
              readOnly = true;
            }
            {
              name = "nix-daemon";
              mountPath = "/nix/var/nix/daemon-socket";
            }
          ];
        };
      };

      # Fails outside a sandbox: a sandboxed builder sees no /var/lib.
      probeDrv = pkgs.writeText "sandbox-probe.nix" ''
        derivation {
          name = "sandbox-probe";
          system = "${pkgs.stdenv.hostPlatform.system}";
          builder = "/bin/sh";
          args = [ "-c" "if [ -e /var/lib ]; then exit 1; fi; echo sandboxed > $out" ];
        }
      '';
    in
    {
      imports = [ base.nodes.node1 ];

      systemd.services.nix-snapshotter = {
        description = "containerd snapshotter that serves nix store paths";
        wantedBy = [ "multi-user.target" ];
        before = [ "containerd.service" ];
        partOf = [ "containerd.service" ];
        path = [ pkgs.nix ];
        serviceConfig = {
          Type = "notify";
          Delegate = "yes";
          KillMode = "mixed";
          Restart = "always";
          RestartSec = 2;
          StateDirectory = "nix-snapshotter";
          RuntimeDirectory = "nix-snapshotter";
          RuntimeDirectoryPreserve = "yes";
          ExecStart = "${lib.getExe' pkgs.nix-snapshotter "nix-snapshotter"} --config ${
            (pkgs.formats.toml { }).generate "config.toml" { }
          }";
        };
      };

      virtualisation.containerd.settings = {
        plugins."io.containerd.grpc.v1.cri".containerd.snapshotter = "nix";
        plugins."io.containerd.transfer.v1.local".unpack_config = [
          {
            platform = "linux/amd64";
            snapshotter = "nix";
          }
        ];
        proxy_plugins.nix = {
          type = "snapshot";
          address = socket;
          # nix-snapshotter does not advertise remap-ids, so for a
          # user-namespaced pod containerd falls back to chowning the whole
          # snapshot, which fails on the read-only store bind mounts. Declared
          # here, containerd passes the id mapping instead; store paths that
          # stay unmapped read as the overflow uid, which a read-only store
          # does not mind.
          capabilities = [ "remap-ids" ];
        };
      };

      services.kubernetes.kubelet.extraOpts = "--image-service-endpoint unix://${socket}";

      environment.etc = {
        "nix-snapshotter-test/plain.json".source = pod "plain" { };
        "nix-snapshotter-test/userns.json".source = pod "userns" (nodeStore // { hostUsers = false; });
        "nix-snapshotter-test/sandbox-probe.nix".source = probeDrv;
      };

      # The derivation's builder is the sandbox's /bin/sh, so the build needs
      # nothing fetched: the VM has no network to fetch from.
      virtualisation.additionalPaths = [ pkgs.busybox-sandbox-shell ];

      # A user-namespaced pod gets its volumes idmapped, and the default VM
      # store is the host's, shared over virtiofs, which refuses
      # MOUNT_ATTR_IDMAP. A disk image puts the store on ext4, as on a real
      # node.
      virtualisation.useBootLoader = true;
    };

  testScript = ''
    start_all()

    node1.wait_for_unit("nix-snapshotter.service")
    node1.wait_for_unit("kubelet.service")
    node1.wait_until_succeeds("kubectl get nodes | grep -q ' Ready'")

    # Registry-style images still run: the seeded coredns image goes through
    # nix-snapshotter's embedded overlay snapshotter.
    node1.wait_until_succeeds(
        "kubectl -n kube-system get deployment coredns"
        " -o jsonpath='{.status.readyReplicas}' | grep -q '^[1-9]'"
    )

    # A nix:0 image, resolved from the node's store. wait_until_succeeds on
    # the apply for the same default-ServiceAccount race the other test has.
    node1.wait_until_succeeds("kubectl apply -f /etc/nix-snapshotter-test/plain.json")
    node1.wait_until_succeeds(
        "kubectl get pod plain -o jsonpath='{.status.phase}' | grep -q Running"
    )

    # The same image in a user-namespaced pod, with the node store and the
    # daemon socket mounted.
    node1.wait_until_succeeds("kubectl apply -f /etc/nix-snapshotter-test/userns.json")
    try:
        node1.wait_until_succeeds(
            "kubectl get pod userns -o jsonpath='{.status.phase}' | grep -q Running",
            timeout=300,
        )
    except Exception:
        # Why it did not start, near the end of the log rather than buried in
        # the kubelet's.
        print(node1.execute("kubectl describe pod userns")[1])
        raise
    uid_map = node1.succeed("kubectl exec userns -- cat /proc/self/uid_map")
    assert not uid_map.split()[:2] == ["0", "0"], f"not user-namespaced: {uid_map}"

    # A build from inside that pod, through the node's daemon, in its sandbox.
    node1.succeed(
        "kubectl cp /etc/nix-snapshotter-test/sandbox-probe.nix userns:/tmp/probe.nix"
    )
    out = node1.succeed(
        "kubectl exec userns -- nix-build --no-out-link /tmp/probe.nix"
    ).strip()
    assert out.startswith("/nix/store/"), out
    assert node1.succeed(f"cat {out}").strip() == "sandboxed"
    assert node1.succeed(f"kubectl exec userns -- cat {out}").strip() == "sandboxed"
  '';
}
