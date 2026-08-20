# pki

Cluster-wide PKI for cairn. Provides the CA (via a clan vars prompt) and
generic cfssl-based certificate generation machinery.

Other services declare their own certificate needs under
`cluster.cairn.pki.certs.<name>` (CN, SANs, cfssl profile, key owner); this
service turns each entry into a `clan.core.vars.generators.cairn-<name>`
that signs against the shared CA and resolves `cert`/`key` paths back onto
the option.

Any machine that consumes a certificate — directly, or indirectly because
another service on that machine declares one — needs the `node` role
assigned.
