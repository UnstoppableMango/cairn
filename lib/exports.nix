{ lib }:
{
  endpointHosts =
    clanLib:
    {
      service,
      role,
    }:
    exports:
    lib.concatMap (e: e.endpoints.hosts) (
      lib.attrValues (
        clanLib.selectExports (scope: scope.serviceName == service && scope.roleName == role) exports
      )
    );
}
