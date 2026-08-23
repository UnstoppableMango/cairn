# Declared once, consumed both as the role's inventory-facing interface
# (default.nix) and as the NixOS options the role module reads
# (control-plane.nix).
{ lib }:
{
  url = lib.mkOption {
    type = lib.types.str;
    description = "Git URL of the GitOps repository Flux syncs from.";
  };

  branch = lib.mkOption {
    type = lib.types.str;
    default = "main";
    description = "Branch of the GitOps repository to track.";
  };

  path = lib.mkOption {
    type = lib.types.str;
    default = "./clusters/cairn";
    description = "Path within the GitOps repository that Flux's root Kustomization targets.";
  };
}
