# The Corefile (control-plane.nix) and the container/Service manifests
# (manifests.nix) have to agree on these, so they live in one place.
# Unprivileged ports: the CoreDNS container drops all capabilities except
# NET_BIND_SERVICE, and the kube-dns Service maps :53 onto them.
{
  dns = 10053;
  health = 10054;
  metrics = 10055;
}
