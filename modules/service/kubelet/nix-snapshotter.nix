{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.cluster.cairn.kubelet.nixSnapshotter;
  socket = "/run/nix-snapshotter/nix-snapshotter.sock";
in
{
  options.cluster.cairn.kubelet.nixSnapshotter = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Run nix-snapshotter as this node's containerd snapshotter and image
        service, so pods can run `nix:0/nix/store/...` images straight off
        the node's nix store. Registry images keep working through its
        embedded overlay snapshotter.

        Switching an existing node discards the images and container
        snapshots containerd holds under its previous snapshotter, so drain
        the node first.
      '';
    };

    package = lib.mkPackageOption pkgs "nix-snapshotter" { };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.nix-snapshotter = {
      description = "containerd snapshotter that serves nix store paths";
      wantedBy = [ "multi-user.target" ];
      before = [ "containerd.service" ];
      partOf = [ "containerd.service" ];
      path = [ config.nix.package ];
      serviceConfig = {
        Type = "notify";
        Delegate = "yes";
        KillMode = "mixed";
        Restart = "always";
        RestartSec = 2;
        StateDirectory = "nix-snapshotter";
        RuntimeDirectory = "nix-snapshotter";
        RuntimeDirectoryPreserve = "yes";
        ExecStart = "${lib.getExe' cfg.package "nix-snapshotter"} --config ${
          (pkgs.formats.toml { }).generate "nix-snapshotter.toml" { }
        }";
      };
    };

    virtualisation.containerd.settings = {
      plugins."io.containerd.grpc.v1.cri".containerd.snapshotter = "nix";
      plugins."io.containerd.transfer.v1.local".unpack_config = [
        {
          platform = "${pkgs.stdenv.hostPlatform.go.GOOS}/${pkgs.stdenv.hostPlatform.go.GOARCH}";
          snapshotter = "nix";
        }
      ];
      proxy_plugins.nix = {
        type = "snapshot";
        address = socket;
        # nix-snapshotter does not advertise remap-ids, so for a
        # user-namespaced pod containerd falls back to chowning the whole
        # snapshot, which fails on the read-only store bind mounts. Declared
        # here, containerd passes the id mapping instead; store paths that
        # stay unmapped read as the overflow uid, which a read-only store
        # does not mind.
        capabilities = [ "remap-ids" ];
      };
    };

    services.kubernetes.kubelet.extraOpts = "--image-service-endpoint unix://${socket}";
  };
}
