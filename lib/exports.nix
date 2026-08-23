{ lib }:
{
  # Every host any machine of `service`'s `role` published under the
  # "endpoints" export interface, flattened. `clanLib` comes from the service
  # module's own arguments; `exports` from `perInstance`.
  #
  # clan's exports mechanism only allows a fixed set of typed interfaces, and
  # "endpoints" (a bare listOf str under `.hosts`) is the closest fit for "an
  # opaque dial string per machine", so both etcd client URLs and apiserver
  # "ip:port" targets travel through it.
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
