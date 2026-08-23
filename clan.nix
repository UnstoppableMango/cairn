{
  self,
  lib,
  ...
}:
let
  cairnLib = self.lib;

  # self.inputs (rather than an `inputs` specialArg) so this resolves the
  # same way regardless of which evalModules pass re-imports clan.nix — the
  # nixosTest driver's per-machine module composition re-imports this file
  # with only NixOS's standard specialArgs (self, lib, pkgs, ...), not
  # flake.nix's custom `inputs` override.
  inherit (self.inputs) inoculant a2b;

  inherit (lib.modules) importApply;
in
{
  meta.name = "cairn";

  modules."@UnstoppableMango/pki" = import ./modules/service/pki;
  modules."@UnstoppableMango/etcd" = importApply ./modules/service/etcd {
    inherit cairnLib;
  };
  modules."@UnstoppableMango/apiserver" = importApply ./modules/service/apiserver {
    inherit cairnLib;
  };
  modules."@UnstoppableMango/kubelet" = importApply ./modules/service/kubelet {
    inherit cairnLib;
  };
  modules."@UnstoppableMango/loadbalancer" = importApply ./modules/service/loadbalancer {
    inherit cairnLib;
  };
  modules."@UnstoppableMango/network" = importApply ./modules/service/network {
    inherit cairnLib;
  };
  modules."@UnstoppableMango/kubeconfig" = importApply ./modules/service/kubeconfig {
    inherit cairnLib;
  };
  modules."@UnstoppableMango/inoculant" = importApply ./modules/service/inoculant {
    inherit inoculant;
  };
  modules."@UnstoppableMango/coredns" = import ./modules/service/coredns;
  modules."@UnstoppableMango/flux" = importApply ./modules/service/flux {
    inherit a2b;
  };
}
