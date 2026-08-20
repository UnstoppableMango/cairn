# apiserver

Runs kube-apiserver, kube-controller-manager, and kube-scheduler
(`services.kubernetes.roles = [ "master" ]`) on control-plane nodes.

Consumes the [etcd](../etcd) service's exported client URLs (via clan's
`endpoints` export interface) to build
`services.kubernetes.apiserver.etcd.servers`. Exports each node's
`ip:apiserverPort` the same way, consumed by the
[loadbalancer](../loadbalancer) service to build its HAProxy backend list.

Needs [pki](../pki) assigned to the same machines for certificates, and
[kubelet](../kubelet)'s `control-plane` role for the kubelet running
alongside the apiserver.
