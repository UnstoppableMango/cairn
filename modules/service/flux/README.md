# flux

Optional Flux (GitOps) bootstrap via inoculant. Builds `gotk-components.yaml`
and `gotk-sync.yaml` at eval time (via the `a2b` flake input's flux library)
the same way `flux bootstrap`/`flux install --export` would, and hands them
to inoculant as raw manifest files.

Requires [inoculant](../inoculant) and [kubeconfig](../kubeconfig) assigned
to the same machine.
