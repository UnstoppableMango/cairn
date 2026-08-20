# pki

Cluster-wide PKI for cairn. Provides the CA (via a clan vars prompt) and
generic cfssl-based certificate generation machinery.

Other services declare their own certificate needs under
`cluster.cairn.pki.certs.<name>` (CN, SANs, cfssl profile, key owner); this
service turns each entry into a
`clan.core.vars.generators.<generatorPrefix>-<name>` that signs against the
shared CA and resolves `cert`/`key` paths back onto the option.
`generatorPrefix` defaults to `cairn` and can be overridden (e.g. when
migrating an existing cluster's PKI trust onto cairn) to match pre-existing
generator names instead of minting new ones.

For bringing in pre-existing cert/key material directly, both the CA
(`cluster.cairn.pki.ca.override`) and individual certs
(`cluster.cairn.pki.certs.<name>.override`) accept a `{ crt, key }` pair of
filesystem paths. When set, the generator copies those files in as-is
instead of prompting (CA) or signing against the CA (certs). Paths are
resolved at `clan vars generate` time on the invoking machine, not copied
into the Nix store.

Any machine that consumes a certificate — directly, or indirectly because
another service on that machine declares one — needs the `node` role
assigned.
