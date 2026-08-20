{ inputs, lib, ... }:
{
  meta.name = "cairn";

  modules."@UnstoppableMango/pki" = import ./modules/service/pki;
  modules."@UnstoppableMango/etcd" = lib.importApply ./modules/service/etcd { inherit inputs; };
  modules."@UnstoppableMango/apiserver" = lib.importApply ./modules/service/apiserver {
    inherit inputs;
  };
  modules."@UnstoppableMango/kubelet" = lib.importApply ./modules/service/kubelet { inherit inputs; };
  modules."@UnstoppableMango/loadbalancer" = lib.importApply ./modules/service/loadbalancer {
    inherit inputs;
  };
  modules."@UnstoppableMango/network" = lib.importApply ./modules/service/network { inherit inputs; };
  modules."@UnstoppableMango/kubeconfig" = lib.importApply ./modules/service/kubeconfig {
    inherit inputs;
  };
  modules."@UnstoppableMango/inoculant" = import ./modules/service/inoculant;
  modules."@UnstoppableMango/coredns" = import ./modules/service/coredns;
  modules."@UnstoppableMango/flux" = import ./modules/service/flux;
}
