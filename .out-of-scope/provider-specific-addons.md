# Provider-specific addons

cairn does not ship addons whose job depends on an external provider, such as external-dns.
They are delivered by Flux, which cairn already bootstraps, not by inoculant.

## Why this is out of scope

cairn's addons (CoreDNS, metrics-server, Flux itself, and kube-state-metrics once it lands) are provider-neutral bootstrap components.
Each is opt-in, but none needs provider-specific configuration, so inoculant can deliver it from eval-time facts and the cluster option tree can describe it completely.
Flux does reach outside the cluster, to a Git repository, but that is one URL and the point of bootstrapping it, not a provider integration.

An addon like external-dns is the opposite on each count:

- Its configuration is mostly about something else: which DNS backend, its address, its credentials, which zones the cluster owns.
  Modelling that in `cairn.clusters.<name>.services` means growing an option surface per provider, and keeping it current as upstream adds flags.
- It commonly runs as several instances in one cluster.
  rosequartz runs one per in-cluster Pi-hole plus one in `coredns-system`, each with its own provider and owner ID.
- It is not needed to bootstrap anything, so it gains nothing from arriving before Flux does.

The one thing cairn would add is an image pinned to the cluster's Kubernetes minor.
kubepkgs builds external-dns per minor already, so a Flux-managed deployment can take that build directly without cairn in the path.

## Prior requests

- #139: "feat(addons): deliver external-dns through inoculant" (split out of #78)
