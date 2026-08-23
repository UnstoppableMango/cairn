{
  # The same modules a real consumer resolves via `inputs.cairn.clan.modules`,
  # passed in by whoever wires this test up (see flake.nix) instead of this
  # file reaching into module source files itself.
  cairnModules,
  # Only used to embed a plain store-path reference (busybox's nslookup) into
  # testScript below. Deliberately not read from `nodes.node1` inside
  # testScript itself: nixosTest strips toplevel-dependent values (like
  # `nixpkgs.pkgs`) out of `nodes.<name>` there, to avoid a testScript ->
  # nodes -> toplevel -> testScript recursion cycle.
  pkgs,
}:
{
  name = "single-node-cluster";

  clan = {
    directory = ./.;

    # etcd/apiserver TLS won't work in containers.
    test.useContainers = false;

    modules = cairnModules;

    imports = [
      (import ../../inventory.nix {
        moduleInput = "self";
        ip = "127.0.0.1";
      })
    ];

    machines.node1 =
      { pkgs, ... }:
      let
        # Throwaway CA, generated at eval time so the pki service's
        # interactive CA prompt (clan vars generate) never fires in the
        # test. Set here (clan.machines.node1) rather than on the nixosTest's
        # `nodes.node1` because vars/generators are computed from
        # clanInternals.machines (fed by clan.machines), a separate
        # evaluation from the nixosTest node config.
        testCa =
          pkgs.runCommand "single-node-test-ca"
            {
              nativeBuildInputs = [ pkgs.cfssl ];
            }
            ''
              mkdir -p "$out"
              echo '{"CN":"single-node-cluster test CA","key":{"algo":"ecdsa","size":256}}' > csr.json
              cfssl gencert -initca csr.json | cfssljson -bare ca
              mv ca.pem "$out/crt"
              mv ca-key.pem "$out/key"
            '';
      in
      {
        services.kubernetes.roles = [ "node" ];

        cluster.cairn.pki.ca.override = {
          crt = "${testCa}/crt";
          key = "${testCa}/key";
        };
      };
  };

  nodes.node1 =
    { pkgs, ... }:
    let
      smokeTestImage = pkgs.dockerTools.buildImage {
        name = "smoke-test";
        tag = "test";
        config.Cmd = [
          "${pkgs.busybox}/bin/sleep"
          "3600"
        ];
      };
    in
    {
      # nixpkgs' flannel v0.28.9 source hash doesn't match the tag's current
      # GitHub archive content (upstream nixpkgs staleness, unrelated to
      # cairn); pin the correct hash here until nixpkgs catches up.
      nixpkgs.overlays = [
        (final: prev: {
          flannel = prev.flannel.overrideAttrs (_old: {
            src = prev.fetchFromGitHub {
              owner = "flannel-io";
              repo = "flannel";
              rev = "v${prev.flannel.version}";
              hash = "sha256-Im/8JB/IfwT3Ne7mSsXH71tEGf53MhSzNLw0pevLjn8=";
            };
          });
        })
      ];

      # No network access in the test VM: seed the smoke-test pod's image
      # locally instead of letting kubelet try to pull it.
      services.kubernetes.kubelet.seedDockerImages = [ smokeTestImage ];
    };

  testScript = ''
    start_all()

    node1.wait_for_unit("etcd.service")
    node1.wait_for_unit("kube-apiserver.service")
    node1.wait_for_unit("kubelet.service")
    node1.wait_for_unit("flannel.service")

    node1.wait_until_succeeds("kubectl get --raw=/healthz")
    node1.wait_until_succeeds("kubectl get nodes | grep -q ' Ready'")

    # No trailing command override: the image's own Cmd already runs sleep by
    # absolute path. Overriding it with a bare "sleep" here would fail to
    # exec, since the container has no $PATH to resolve it against.
    #
    # wait_until_succeeds, not succeed: node Ready doesn't imply the
    # controller-manager has finished creating the default namespace's
    # default ServiceAccount yet, so the first attempt can race it and fail
    # with "serviceaccount default not found". A failed `kubectl run` creates
    # no pod, so retrying is safe.
    node1.wait_until_succeeds(
        "kubectl run smoke-test --image=smoke-test:test --image-pull-policy=Never"
        " --restart=Never"
    )
    node1.wait_until_succeeds(
        "kubectl get pod smoke-test -o jsonpath='{.status.phase}' | grep -q Running"
    )

    # inoculant bootstraps as a kubelet static pod and applies the coredns
    # manifests once the apiserver is reachable; wait for the Deployment it
    # creates to actually roll a replica out.
    node1.wait_until_succeeds(
        "kubectl -n kube-system get deployment coredns"
        " -o jsonpath='{.status.readyReplicas}' | grep -q '^[1-9]'"
    )

    # Prove DNS actually resolves in-cluster, not just that the Deployment is
    # Ready. `kubectl exec`/`kubectl logs` both require the apiserver to
    # dial kubelet directly over TLS, which this test's PKI setup doesn't
    # support (kubelet's serving cert has no SAN for "node1"). Route around
    # that by running the lookup as the pod's own command and reading the
    # result back from the Pod's phase (reported by kubelet's normal
    # outbound status updates, no apiserver->kubelet dial needed) instead
    # of execing into it or streaming its logs. busybox's nslookup exits
    # non-zero on SERVFAIL/NXDOMAIN/timeout, so restartPolicy=Never turns
    # that into Pod phase Failed rather than Succeeded.
    node1.wait_until_succeeds(
        "kubectl run dns-test --image=smoke-test:test --image-pull-policy=Never"
        " --restart=Never --command -- ${pkgs.busybox}/bin/nslookup kubernetes.default"
    )
    node1.wait_until_succeeds(
        "kubectl get pod dns-test -o jsonpath='{.status.phase}' | grep -q Succeeded"
    )
    '';
}
