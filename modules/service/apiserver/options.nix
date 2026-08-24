{ lib }:
{
  apiserverPort = lib.mkOption {
    type = lib.types.port;
    default = 6444;
    description = "Port the local apiserver binds to (fronted externally by loadbalancer at the VIP).";
  };

  serviceClusterIP = lib.mkOption {
    type = lib.types.str;
    default = "10.0.0.1";
    description = "First IP of the service CIDR; included in apiserver SANs.";
  };
}
