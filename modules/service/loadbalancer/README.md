# loadbalancer

Keepalived VRRP virtual IP plus an HAProxy TCP proxy fronting the apiserver
cluster: `VIP:6443` → round-robin to each apiserver node's internal port.

- **keepalived** — all assigned nodes run in `BACKUP` state; highest
  `keepalivedPriority` wins the VIP.
- **HAProxy** — binds the VIP on `:6443`, backends built from the
  [apiserver](../apiserver) service's exported `ip:port` list (clan's
  `endpoints` export interface).
