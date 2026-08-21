{
  meta.name = "cairn";

  modules."@UnstoppableMango/pki" = import ./modules/service/pki;
  modules."@UnstoppableMango/etcd" = import ./modules/service/etcd;
  modules."@UnstoppableMango/apiserver" = import ./modules/service/apiserver;
  modules."@UnstoppableMango/kubelet" = import ./modules/service/kubelet;
  modules."@UnstoppableMango/loadbalancer" = import ./modules/service/loadbalancer;
  modules."@UnstoppableMango/network" = import ./modules/service/network;
  modules."@UnstoppableMango/kubeconfig" = import ./modules/service/kubeconfig;
  modules."@UnstoppableMango/inoculant" = import ./modules/service/inoculant;
  modules."@UnstoppableMango/coredns" = import ./modules/service/coredns;
  modules."@UnstoppableMango/flux" = import ./modules/service/flux;
}
