# Project Goals

Provide a production-grade kubernetes implementation on top of NixOS.
NixOS modules are leaned on heavily for components and configuration.
A clan (clan.lol) service configuring the cluster on machines is the primary entrypoint.
Start small, use nixpkgs `services.kubernetes` and copy `github:UnstoppableMango/nixos/modules/services/rosequartz`.
