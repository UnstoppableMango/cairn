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

    node1.wait_until_succeeds(
        "kubectl -n kube-system get deployment coredns"
        " -o jsonpath='{.status.readyReplicas}' | grep -q '^[1-9]'"
    )

    node1.wait_until_succeeds(
        "kubectl get node node1 -o jsonpath='{.metadata.labels}'"
        " | grep -q 'node-role.kubernetes.io/control-plane'"
    )
  '';
}
