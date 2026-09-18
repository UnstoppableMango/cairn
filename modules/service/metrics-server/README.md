# metrics-server

Optional [metrics-server](https://github.com/kubernetes-sigs/metrics-server)
bootstrap via inoculant, serving the Metrics API (`kubectl top`, and the
resource metrics HPAs read).

Manifests (ServiceAccount, the `system:metrics-server` and
`system:aggregated-metrics-reader` ClusterRoles with their bindings, the
`extension-apiserver-authentication-reader` RoleBinding, Deployment, Service
and the `v1beta1.metrics.k8s.io` APIService) are hand-authored in
`./manifests.nix`, the same way [coredns](../coredns) handles its own.

The container image is built from kubepkgs' `metrics-server` for the cluster's
pinned Kubernetes minor and seeded onto the assigned machines that run a
kubelet; the Deployment is pinned to `nodeNames` via node affinity and
matching tolerations. nixpkgs ships no metrics-server, so a cluster that pins
no minor takes kubepkgs' newest.

Scrapes kubelets over TLS verified against the cluster CA, which the pod
mounts off the node, with `--kubelet-preferred-address-types=InternalIP`
because the kubelet serving cert's only SAN is the machine's advertise
address. `nodeNames` must therefore name machines that have [pki](../pki)
assigned. `extraArgs = [ "--kubelet-insecure-tls" ]` opts out.

The apiserver's own hop to metrics-server skips TLS verification
(`insecureSkipTLSVerify` on the APIService), since metrics-server serves on a
self-signed certificate it generates at startup. That hop is authenticated in
the other direction, by the front-proxy client certificate the
[apiserver](../apiserver) service presents, which is also what makes the
aggregation layer work here at all.

Requires [inoculant](../inoculant), [kubeconfig](../kubeconfig) and
[pki](../pki) assigned to the same machine.
