{
  cairnModules,
}:
{
  name = "single-node-cluster";

  clan = {
    directory = ./.;

    test.useContainers = false;

    modules = cairnModules;

    imports = [
      (import ../../inventory.nix {
        moduleInput = "self";
        # The test VM's own address on vlan 1, which the NixOS test
        # framework assigns as 192.168.<vlan>.<nodeNumber>. Not 127.0.0.1:
        # the apiserver refuses to advertise an address in the loopback
        # range when the endpoint reconciler maintains the kubernetes
        # service endpoints, which is the default.
        ip = "192.168.1.1";
      })
    ];

    machines.node1 =
      { pkgs, ... }:
      let
        # Throwaway root and intermediate, generated at eval time so the pki
        # service's interactive CA prompt (clan vars generate) never fires in
        # the test. The intermediate is the cluster CA and the root is its
        # chain, the shape of a cluster CA issued by an organisation root.
        # Set here (clan.machines.node1) rather than on the nixosTest's
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
              echo '{"CN":"single-node-cluster test root","key":{"algo":"ecdsa","size":256}}' > root.json
              cfssl gencert -initca root.json | cfssljson -bare root
              echo '{"CN":"single-node-cluster test CA","key":{"algo":"ecdsa","size":256}}' > ca.json
              cfssl genkey -initca ca.json | cfssljson -bare ca
              echo '{"signing":{"default":{"expiry":"87600h","usages":["cert sign","crl sign"],"ca_constraint":{"is_ca":true,"max_path_len":0,"max_path_len_zero":true}}}}' > config.json
              cfssl sign -ca root.pem -ca-key root-key.pem -config config.json ca.csr | cfssljson -bare ca
              mv root.pem "$out/root"
              mv ca.pem "$out/crt"
              mv ca-key.pem "$out/key"
            '';
      in
      {
        services.kubernetes.roles = [ "node" ];

        cluster.cairn.pki.ca = {
          override = {
            crt = "${testCa}/crt";
            key = "${testCa}/key";
          };
          chain = [ (builtins.readFile "${testCa}/root") ];
        };
      };
  };

  nodes.node1 =
    { pkgs, ... }:
    let
      # busybox linked into /bin so the test script can exec tools inside the
      # container by a path that does not depend on a store path, which the
      # test script cannot interpolate from here anyway.
      smokeTestImage = pkgs.dockerTools.buildImage {
        name = "smoke-test";
        tag = "test";
        copyToRoot = pkgs.buildEnv {
          name = "smoke-test-root";
          paths = [ pkgs.busybox ];
          pathsToLink = [ "/bin" ];
        };
        config.Cmd = [
          "/bin/sleep"
          "3600"
        ];
      };
    in
    {
      services.kubernetes.kubelet.seedDockerImages = [ smokeTestImage ];

      environment.systemPackages = [ pkgs.openssl ];

      # The seeded images (coredns, metrics-server, the pause shim and this
      # test's own) land in containerd's store on the VM's writable disk. The
      # NixOS test default is small enough that kubelet's image garbage
      # collector crosses its disk-usage threshold and deletes the seeded
      # images, which then cannot be re-pulled: every pod fails with
      # ErrImageNeverPull long after the import succeeded.
      virtualisation.diskSize = 8192;
      virtualisation.memorySize = 4096;
    };

  testScript = ''
    start_all()

    node1.wait_for_unit("etcd.service")
    node1.wait_for_unit("kube-apiserver.service")
    node1.wait_for_unit("kubelet.service")
    node1.wait_for_unit("flannel.service")

    node1.wait_until_succeeds("kubectl get --raw=/healthz")
    node1.wait_until_succeeds("kubectl get nodes | grep -q ' Ready'")

    # The bundle pods trust verifies the apiserver under OpenSSL, which,
    # unlike Go, rejects a trust bundle that stops at an intermediate.
    node1.wait_until_succeeds(
        "kubectl get configmap kube-root-ca.crt -o jsonpath='{.data.ca\\.crt}'"
        " > /tmp/kube-root-ca.crt"
    )
    node1.succeed(
        "openssl s_client -connect 192.168.1.1:6443 -CAfile /tmp/kube-root-ca.crt"
        " -verify_return_error </dev/null"
    )

    # No trailing command override: the image's own Cmd already runs sleep by
    # absolute path. Overriding it with a bare "sleep" here would fail to
    # exec, since the container has no $PATH to resolve it against, which is
    # also why the exec below spells out /bin/nslookup.
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

    node1.wait_until_succeeds(
        "kubectl -n kube-system get deployment coredns"
        " -o jsonpath='{.status.readyReplicas}' | grep -q '^[1-9]'"
    )

    # Cluster DNS end to end, not just a ready Deployment: the pod's
    # resolver, the kube-dns ClusterIP, kube-proxy's rule for it, and
    # CoreDNS' answer for an in-cluster Service all have to line up.
    node1.wait_until_succeeds(
        "kubectl exec smoke-test -- /bin/nslookup"
        " kubernetes.default.svc.cluster.local"
    )

    # metrics-server: the Deployment lands on the node whose image was
    # seeded, the aggregation layer routes the Metrics API to it, and a
    # scrape of the local kubelet succeeds over TLS verified against the
    # cluster CA. `kubectl top` is the only one of the three that proves the
    # scrape itself worked.
    node1.wait_until_succeeds(
        "kubectl -n kube-system get deployment metrics-server"
        " -o jsonpath='{.status.readyReplicas}' | grep -q '^[1-9]'"
    )
    node1.wait_until_succeeds(
        "kubectl get apiservice v1beta1.metrics.k8s.io"
        " -o jsonpath='{.status.conditions[?(@.type==\"Available\")].status}'"
        " | grep -q True"
    )
    node1.wait_until_succeeds("kubectl top node node1 | grep -q node1")

    node1.wait_until_succeeds(
        "kubectl get node node1 -o jsonpath='{.metadata.labels}'"
        " | grep -q 'node-role.kubernetes.io/control-plane'"
    )
  '';
}
