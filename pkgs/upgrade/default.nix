# `cairn-upgrade`: the rollout orchestrator from docs/UPGRADES.md, phase 2.
{
  lib,
  buildGoModule,
  makeWrapper,
  clan-cli,
  openssh,
}:
buildGoModule {
  pname = "cairn-upgrade";
  version = "0.1.0";

  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./go.mod
      ./go.sum
      (lib.fileset.fileFilter (file: file.hasExt "go") ./.)
    ];
  };

  vendorHash = "sha256-6DFqyyNc++R2w5wiHlA96ttX05o3e3NmC8ETAyHB72M=";

  env.CGO_ENABLED = 0;
  ldflags = [
    "-s"
    "-w"
  ];

  nativeBuildInputs = [ makeWrapper ];

  # The binary is named after the package directory. `nix` is deliberately
  # left off the PATH: the plan is evaluated with the caller's own nix, the
  # same one that evaluates the machines `clan` deploys.
  postInstall = ''
    mv $out/bin/upgrade $out/bin/cairn-upgrade
    wrapProgram $out/bin/cairn-upgrade \
      --prefix PATH : ${
        lib.makeBinPath [
          clan-cli
          openssh
        ]
      }
  '';

  meta = {
    description = "Rolls a cairn cluster one machine at a time, gated on etcd, apiserver and node health";
    mainProgram = "cairn-upgrade";
    license = lib.licenses.mit;
  };
}
