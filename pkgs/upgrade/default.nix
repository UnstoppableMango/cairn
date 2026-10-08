# `cairn-upgrade`: the rollout orchestrator from docs/UPGRADES.md, phase 2.
# Shell, since all it does is sequence other tools; see ./cairn-upgrade.sh.
{
  writeShellApplication,
  clan-cli,
  coreutils,
  curl,
  etcd,
  jq,
  kubectl,
  openssh,
}:
writeShellApplication {
  name = "cairn-upgrade";
  # `nix` is deliberately absent: the plan is evaluated with the caller's own
  # nix, the same one that evaluates the machines `clan` deploys.
  runtimeInputs = [
    clan-cli
    coreutils
    curl
    # etcdctl ships inside nixpkgs' server package.
    etcd
    jq
    kubectl
    openssh
  ];
  text = builtins.readFile ./cairn-upgrade.sh;
}
