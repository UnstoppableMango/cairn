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
        # Not 127.0.0.1: the apiserver refuses to advertise a loopback address while the endpoint reconciler maintains the kubernetes service.
        ip = "192.168.1.1";
      })
    ];

    machines.node1 =
      { pkgs, ... }:
      let
        # Generated at eval time so the CA prompt never fires, with the intermediate as cluster CA, the shape of one issued by an organisation root.
        # Set on clan.machines rather than the nixosTest's `nodes.node1`, because vars are computed from clanInternals.machines, a separate evaluation.
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
      # busybox in /bin, since the test script cannot interpolate a store path from here.
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

      # Checks etcdctl and kubectl work for someone other than root.
      users.users.admin = {
        isNormalUser = true;
        extraGroups = [ "wheel" ];
      };

      # On the test default disk, kubelet's image GC crosses its threshold and deletes the seeded images, which cannot be re-pulled, so pods fail with ErrImageNeverPull.
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

    # sudo resets the environment, so this proves the wrapper defaults; `--endpoints` must work beside them, since etcdctl refuses a flag duplicating an ETCDCTL_* variable.
    node1.succeed("sudo -u admin etcdctl endpoint health")
    node1.succeed("sudo -u admin etcdctl --endpoints=https://192.168.1.1:2379 member list")
    node1.succeed("sudo -u admin kubectl get nodes")
    node1.succeed("env -i HOME=/root /run/current-system/sw/bin/etcdctl endpoint health")
    node1.succeed("env -i HOME=/root /run/current-system/sw/bin/kubectl get nodes")

    # OpenSSL, unlike Go, rejects a trust bundle that stops at an intermediate.
    node1.wait_until_succeeds(
        "kubectl get configmap kube-root-ca.crt -o jsonpath='{.data.ca\\.crt}'"
        " > /tmp/kube-root-ca.crt"
    )
    node1.succeed(
        "openssl s_client -connect 192.168.1.1:6443 -CAfile /tmp/kube-root-ca.crt"
        " -verify_return_error </dev/null"
    )

    # No command override: the container has no $PATH to resolve a bare "sleep", which is also why the exec spells out /bin/nslookup.
    # Retried because node Ready does not imply the default ServiceAccount exists yet; a failed `kubectl run` creates no pod.
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

    node1.wait_until_succeeds(
        "kubectl exec smoke-test -- /bin/nslookup"
        " kubernetes.default.svc.cluster.local"
    )

    # Only `kubectl top` proves the kubelet scrape itself worked.
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
