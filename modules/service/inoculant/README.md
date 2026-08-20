# inoculant

Imports `inputs.inoculant`'s NixOS module and points its `clusterAdmin` cert
at the [kubeconfig](../kubeconfig) service's `admin-cert`, rather than
minting a dedicated one — inoculant's own cert-generation path relies on
nixpkgs' certmgr/easyCerts flow, which cairn doesn't run.

Shared by [coredns](../coredns) and [flux](../flux); assign this service
(and `kubeconfig`) to any machine that runs either of them.
