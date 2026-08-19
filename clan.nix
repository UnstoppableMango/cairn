{ inputs, ... }:
{
  meta.name = "cairn";

  modules."@UnstoppableMango/cairn" = import ./modules/service/cairn;
}
