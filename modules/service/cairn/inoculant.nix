{
  config,
  inputs,
  ...
}:
let
  cfg = config.cluster.cairn;
in
{
  imports = [ inputs.inoculant.nixosModules.default ];

  # Single source of truth for the inoculant clusterAdmin cert: reuses the
  # kubernetes-admin cert from kubeconfig.nix rather than minting a dedicated
  # one; inoculant's init container uses it to mint scoped RBAC + a token
  # kubeconfig. coredns.nix and flux.nix each contribute their own
  # manifests/manifestFiles into services.kubernetes.inoculant but never
  # touch clusterAdmin.
  config.services.kubernetes.inoculant.clusterAdmin = {
    cert = cfg.pki.certs."admin-cert".cert;
    key = cfg.pki.certs."admin-cert".key;
  };
}
