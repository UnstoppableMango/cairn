# Everything this file injects into services arrives by lexical closure from
# flake.nix (`importApply`), the same way ./flakeModules/default.nix gets
# `cairnInputs`. Nothing here reads an `inputs` module argument, and nothing
# reaches back through `self`: `clan.specialArgs` does not supply module
# arguments to clan.nix, so an `inputs` argument would fall back to
# `_module.args.inputs`, which nothing defines, and blow up with
# `error: attribute 'inputs' missing` once a machine is actually assigned the
# role ([#37](https://github.com/UnstoppableMango/cairn/issues/37)).
{
  cairnLib,
  inoculant,
  a2b,
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
