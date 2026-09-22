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

Since generator names must agree across every machine in the cluster,
`generatorPrefix` (and `certValidityDays`) are exposed as settings on the
`node` role, so a migrating consumer sets them once in the inventory instead
of via `roles.node.extraModules`:

```nix
roles.node.tags.all = {
  settings.generatorPrefix = "mycluster";
};
```

For bringing in pre-existing cert/key material directly, both the CA
(`cluster.cairn.pki.ca.override`) and individual certs
(`cluster.cairn.pki.certs.<name>.override`) accept a `{ crt, key }` pair of
filesystem paths. When set, the generator copies those files in as-is
instead of prompting (CA) or signing against the CA (certs). Paths are
resolved at `clan vars generate` time on the invoking machine, not copied
into the Nix store.

When the cluster CA is an intermediate, set `caChain` on the `node` role to
the PEM certificates of its issuers, up to and including the self-signed
root:

```nix
roles.node.settings.caChain = [ (builtins.readFile ./root-ca.crt) ];
```

The CA followed by that chain is exposed as `cluster.cairn.pki.ca.bundle`,
and the controller-manager publishes it to every namespace as
`kube-root-ca.crt`, the `ca.crt` pods mount alongside their service account
token. Go clients accept the intermediate alone as a trust anchor, but
OpenSSL-based clients (Python, the Ceph mgr's rook module, curl) reject a
bundle that does not end at a self-signed root. The chain is never added to
a client CA file: trusting the root there would let any certificate it
issues authenticate to the apiserver.

Any machine that consumes a certificate — directly, or indirectly because
another service on that machine declares one — needs the `node` role
assigned.
