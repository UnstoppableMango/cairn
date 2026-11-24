{
  cairnModules,
  globset,
}:
# Settles what a real node needs before adopting nix-snapshotter: a user-namespaced pod on a nix-snapshotter image, which does not advertise containerd's id-remapping capability; a sandboxed build from that pod through the node daemon; and registry images still running under it.
let
  base = import ../vm/default.nix { inherit cairnModules; };
in
base
// {
  name = "nix-snapshotter";

  nodes.node1 =
    { lib, pkgs, ... }:
    let
      # nixpkgs' `nix-snapshotter.buildImage` passthru omits the `globset` argument upstream's package.nix requires, so it fails to evaluate.
      nix-snapshotter = pkgs.callPackage "${pkgs.nix-snapshotter.src}/package.nix" {
        inherit globset;
      };

      image = nix-snapshotter.buildImage {
        name = "store-probe";
        resolvedByNix = true;
        copyToRoot = [
          (pkgs.buildEnv {
            name = "store-probe-root";
            paths = [
              pkgs.busybox
              pkgs.nix
            ];
            pathsToLink = [ "/bin" ];
          })
          # In a user-namespaced pod the root filesystem belongs to the host's root, so runc cannot create a missing mount point.
          (pkgs.runCommand "store-probe-mountpoints" { } ''
            mkdir -p $out/tmp $out/nix/var/nix/daemon-socket \
              $out/var/run/secrets/kubernetes.io/serviceaccount
          '')
        ];
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

      # The whole store, so a path the daemon builds is visible to the pod; /tmp is HOME, for nix's cache.
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

      cluster.cairn.kubelet.nixSnapshotter.enable = true;

      environment.etc = {
        "nix-snapshotter-test/plain.json".source = pod "plain" { };
        "nix-snapshotter-test/userns.json".source = pod "userns" (nodeStore // { hostUsers = false; });
        "nix-snapshotter-test/sandbox-probe.nix".source = probeDrv;
      };

      # The builder is the sandbox's /bin/sh, since the VM has no network to fetch from.
      virtualisation.additionalPaths = [ pkgs.busybox-sandbox-shell ];

      # Idmapped volumes need a real filesystem: the default VM store is virtiofs, which refuses MOUNT_ATTR_IDMAP.
      virtualisation.useBootLoader = true;
      # The image's filesystem fits only the store closure, so it is grown into a larger sparse disk at boot for containerd's images and etcd.
      virtualisation.diskSize = lib.mkForce 20480;
      boot.growPartition = true;
      # Not `fileSystems`, which the VM module replaces through mkVMOverride.
      virtualisation.fileSystems."/".autoResize = true;
    };

  testScript = ''
    # 300s rather than 900s, and a failure prints the cluster's state, so a broken run explains itself at the end of the log.
    TIMEOUT = 300
    UNITS = ["etcd", "kube-apiserver", "kubelet", "containerd", "nix-snapshotter"]

    def diagnose(pod=None):
        for unit in UNITS:
            print(f"--- journal: {unit}")
            print(node1.execute(f"journalctl --no-pager -n 25 -u {unit}")[1])
        print("--- pods")
        print(node1.execute("kubectl get pods -A -o wide")[1])
        if pod:
            print(f"--- pod {pod}")
            print(node1.execute(f"kubectl describe pod {pod}")[1])

    def step(action, pod=None):
        try:
            return action()
        except Exception:
            diagnose(pod)
            raise

    def wait(command, pod=None):
        return step(lambda: node1.wait_until_succeeds(command, timeout=TIMEOUT), pod)

    start_all()

    step(lambda: node1.wait_for_unit("nix-snapshotter.service", timeout=TIMEOUT))
    step(lambda: node1.wait_for_unit("kubelet.service", timeout=TIMEOUT))
    wait("kubectl get nodes | grep -q ' Ready'")

    wait(
        "kubectl -n kube-system get deployment coredns"
        " -o jsonpath='{.status.readyReplicas}' | grep -q '^[1-9]'"
    )

    # Retrying covers the default-ServiceAccount race.
    wait("kubectl apply -f /etc/nix-snapshotter-test/plain.json")
    wait("kubectl get pod plain -o jsonpath='{.status.phase}' | grep -q Running", "plain")

    wait("kubectl apply -f /etc/nix-snapshotter-test/userns.json")
    wait("kubectl get pod userns -o jsonpath='{.status.phase}' | grep -q Running", "userns")
    uid_map = node1.succeed("kubectl exec userns -- cat /proc/self/uid_map")
    assert not uid_map.split()[:2] == ["0", "0"], f"not user-namespaced: {uid_map}"

    # The expression is a store path, so the pod sees it through the store mount; the /etc entry is only a symlink.
    probe = node1.succeed("readlink -f /etc/nix-snapshotter-test/sandbox-probe.nix").strip()
    # The driver does not log a failed command's output.
    status, output = node1.execute(
        f"kubectl exec userns -- nix-build --no-out-link {probe} 2>&1"
    )
    print(output)
    if status != 0:
        diagnose("userns")
        print("--- journal: nix-daemon")
        print(node1.execute("journalctl --no-pager -n 40 -u nix-daemon")[1])
        raise Exception(f"nix-build in the userns pod failed (exit {status})")
    out = output.strip().splitlines()[-1]
    assert out.startswith("/nix/store/"), out
    assert node1.succeed(f"cat {out}").strip() == "sandboxed"
    assert node1.succeed(f"kubectl exec userns -- cat {out}").strip() == "sandboxed"
  '';
}
