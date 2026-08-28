# loadbalancer

Keepalived VRRP virtual IP plus an HAProxy TCP proxy fronting the apiserver
cluster: `VIP:6443` → round-robin to each apiserver node's internal port.

- **keepalived** — all assigned nodes run in `BACKUP` state; highest
  `keepalivedPriority` wins the VIP.
- **HAProxy** — binds the VIP on `:6443`, backends built from the
  [apiserver](../apiserver) service's exported `ip:port` list (clan's
  `endpoints` export interface).

## Health checking

With `healthCheck.enable` (the default), readiness drives both layers rather
than reachability:

- HAProxy probes each backend's `/readyz` over TLS (`option httpchk`) and
  takes an unready apiserver out of rotation.
- keepalived runs a track script against the local apiserver's `/readyz` and
  subtracts `healthCheck.weight` (default 60) from the VRRP priority while it
  fails, so the VIP moves off a machine whose apiserver is down, not only one
  whose keepalived is down. Keep the weight larger than the priority gap
  between any two machines.

`healthCheck.interval`, `.fall` and `.rise` tune the keepalived probe cadence.
Disabling the health check falls back to plain TCP checks and a
priority-only VIP election.
