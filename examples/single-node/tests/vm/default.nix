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
    { pkgs, lib, ... }:
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
      # Generate the whole PKI chain as plain build-time derivations instead
      # of clan vars generators: clan's vars machinery forces an IFD during
      # nixosTest evaluation (see modules/service/pki/node.nix's `inline`
      # option), which this flake disallows.
      cluster.cairn.pki.inline = true;

      # clan-core's test framework unconditionally overrides this to a
      # derivation that merges in generated vars/secrets (also IFD); nothing
      # here uses vars anymore, so force it back to the plain source dir.
      clan.core.settings.directory = lib.mkForce ./.;

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
