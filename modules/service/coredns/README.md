# coredns

Optional CoreDNS manifest bootstrap via inoculant. Manifests are harvested
from `config.services.kubernetes.addonManager.addons` (populated by
nixpkgs' `addons.dns` module, which is `mkDefault`-enabled but never applied
since `addonManager.enable = false`) rather than hand-written.

Requires [inoculant](../inoculant) and [kubeconfig](../kubeconfig) assigned
to the same machine.
