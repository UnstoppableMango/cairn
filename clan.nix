{
  self,
  lib,
  ...
}:
let
  cairnLib = self.lib;
in
{
  meta.name = "cairn";

  modules."@UnstoppableMango/pki" = import ./modules/service/pki;
  modules."@UnstoppableMango/etcd" = lib.modules.importApply ./modules/service/etcd {
    inherit cairnLib;
  };
  modules."@UnstoppableMango/apiserver" = lib.modules.importApply ./modules/service/apiserver {
    inherit cairnLib;
  };
  modules."@UnstoppableMango/kubelet" = lib.modules.importApply ./modules/service/kubelet {
    inherit cairnLib;
  };
  modules."@UnstoppableMango/loadbalancer" = lib.modules.importApply ./modules/service/loadbalancer {
    inherit cairnLib;
  };
  modules."@UnstoppableMango/network" = lib.modules.importApply ./modules/service/network {
    inherit cairnLib;
  };
  modules."@UnstoppableMango/kubeconfig" = lib.modules.importApply ./modules/service/kubeconfig {
    inherit cairnLib;
  };
  # self.inputs (rather than an `inputs` specialArg) so this resolves the
  # same way regardless of which evalModules pass re-imports clan.nix — the
  # nixosTest driver's per-machine module composition re-imports this file
  # with only NixOS's standard specialArgs (self, lib, pkgs, ...), not
  # flake.nix's custom `inputs` override.
  modules."@UnstoppableMango/inoculant" = lib.modules.importApply ./modules/service/inoculant {
    inherit (self.inputs) inoculant;
  };
  modules."@UnstoppableMango/coredns" = import ./modules/service/coredns;
  modules."@UnstoppableMango/flux" = lib.modules.importApply ./modules/service/flux {
    inherit (self.inputs) a2b;
  };
}
