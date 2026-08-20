{
  config,
  inputs,
  ...
}:
{
  imports = [ inputs.inoculant.nixosModules.default ];

  config.services.kubernetes.inoculant.clusterAdmin = {
    cert = config.cluster.cairn.pki.certs."admin-cert".cert;
    key = config.cluster.cairn.pki.certs."admin-cert".key;
  };
}
