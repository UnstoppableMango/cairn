{
  # The same modules a real consumer resolves via `inputs.cairn.clan.modules`,
  # passed in by whoever wires this test up (see flake.nix) instead of this
  # file reaching into module source files itself.
  cairnModules,
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

    machines.node1 = {
      services.kubernetes.roles = [ "node" ];
    };
  };

  nodes.node1 =
    { pkgs, ... }:
    let
      # Throwaway CA, generated at eval time so the pki service's interactive
      # CA prompt (clan vars generate) never fires in the test.
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
      cluster.cairn.pki.ca.override = {
        crt = "${testCa}/crt";
        key = "${testCa}/key";
      };

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

    node1.succeed("kubectl get --raw=/healthz")
    node1.wait_until_succeeds("kubectl get nodes | grep -q ' Ready'")

    node1.succeed(
        "kubectl run smoke-test --image=smoke-test:test --image-pull-policy=Never"
        " --restart=Never -- sleep 3600"
    )
    node1.wait_until_succeeds(
        "kubectl get pod smoke-test -o jsonpath='{.status.phase}' | grep -q Running"
    )
  '';
}
