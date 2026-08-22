# network

Flannel CNI pod networking (`services.flannel`, driven directly rather than
via `services.kubernetes.flannel`), plus the kernel bridge/forwarding
settings every CNI-enabled node needs (`br_netfilter`, `net.ipv4.ip_forward`,
etc). Assigned to every control-plane and worker machine.

Also defines kube-proxy's client certificate (`kube-proxy-cert`), consumed
by [kubelet](../kubelet)'s `services.kubernetes.proxy.kubeconfig`.

Needs [pki](../pki) assigned to the same machines for the flannel and
kube-proxy client certificates, and a running apiserver reachable at the
VIP.
