{ inputs, ... }:
{
  meta.name = "cairn";

  modules."@UnstoppableMango/rosequartz" = import ./modules/service/rosequartz;
}
