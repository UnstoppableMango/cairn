{
  self,
  lib,
  inputs,
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
  modules."@UnstoppableMango/inoculant" = lib.modules.importApply ./modules/service/inoculant {
    inherit (inputs) inoculant;
  };
  modules."@UnstoppableMango/coredns" = import ./modules/service/coredns;
  modules."@UnstoppableMango/flux" = lib.modules.importApply ./modules/service/flux {
    inherit (inputs) a2b;
  };
}
