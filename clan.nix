# Don't add an `inputs` module argument here: `clan.specialArgs` doesn't supply
# one to clan.nix, so it falls back to `_module.args.inputs` (undefined) and
# blows up with `error: attribute 'inputs' missing` once a machine is assigned
# the role. Everything needed arrives via lexical closure instead (#37).
{
  cairnLib,
  inoculant,
  a2b,
  kubepkgs,
}:
{ lib, ... }:
let
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
    inherit cairnLib kubepkgs;
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
