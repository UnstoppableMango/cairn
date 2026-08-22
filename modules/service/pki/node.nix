{
  config,
  lib,
  pkgs,
  ...
}:
let
  topConfig = config;
  cfg = config.cluster.cairn;

  # ─── Config (JSON) ───────────────────────────────────────────────────────────

  expiryHours = cfg.pki.certValidityDays * 24;
  prefix = cfg.pki.generatorPrefix;

  signingConfigFile = pkgs.writeText "cfssl-signing-config.json" (
    builtins.toJSON {
      signing = {
        default.expiry = "${toString expiryHours}h";
        profiles = {
          server = {
            expiry = "${toString expiryHours}h";
            usages = [
              "digital signature"
              "server auth"
            ];
          };
          client = {
            expiry = "${toString expiryHours}h";
            usages = [
              "digital signature"
              "client auth"
            ];
          };
          peer = {
            expiry = "${toString expiryHours}h";
            usages = [
              "digital signature"
              "server auth"
              "client auth"
            ];
          };
        };
      };
    }
  );

  mkCsrFile =
    name: cert:
    pkgs.writeText "${name}-csr.json" (
      builtins.toJSON {
        CN = cert.cn;
        key = {
          algo = "ecdsa";
          size = 256;
        };
        hosts = cert.hosts;
        names = lib.optional (cert.org != null) { O = cert.org; };
      }
    );

  # ─── Scripting ───────────────────────────────────────────────────────────────

  gencert = profile: csrFile: ''
    set -euo pipefail
    cfssl gencert \
      -ca "$in/${prefix}-ca/crt" \
      -ca-key "$in/${prefix}-ca/key" \
      -config ${signingConfigFile} \
      -profile ${profile} \
      ${csrFile} | cfssljson -bare cert
    mv cert.pem "$out/crt"
    mv cert-key.pem "$out/key"
    rm -f cert.csr
  '';

  copyOverride = override: ''
    set -euo pipefail
    cp ${lib.escapeShellArg override.crt} "$out/crt"
    cp ${lib.escapeShellArg override.key} "$out/key"
  '';

  mkGenerator =
    name: cert:
    if cert.override != null then
      {
        inherit (cert) share;
        files."crt".secret = false;
        files."key" = {
          secret = true;
          owner = cert.owner;
        };
        script = copyOverride cert.override;
      }
    else
      {
        inherit (cert) share;
        runtimeInputs = [ pkgs.cfssl ];
        dependencies = [ "${prefix}-ca" ];
        files."crt".secret = false;
        files."key" = {
          secret = true;
          owner = cert.owner;
        };
        script = gencert cert.profile (mkCsrFile "${prefix}-${name}" cert);
      };

  # Plain build-time derivations mirroring the generator scripts above, used
  # when `inline` is set to bypass clan's vars/generator machinery entirely
  # (that machinery forces an IFD during nixosTest evaluation; see
  # examples/single-node/tests/vm/default.nix).
  inlineCaDrv =
    if cfg.pki.ca.override != null then
      pkgs.runCommand "${prefix}-ca-inline" { } ''
        mkdir -p "$out"
        cp ${lib.escapeShellArg cfg.pki.ca.override.crt} "$out/crt"
        cp ${lib.escapeShellArg cfg.pki.ca.override.key} "$out/key"
      ''
    else
      pkgs.runCommand "${prefix}-ca-inline" { nativeBuildInputs = [ pkgs.cfssl ]; } ''
        mkdir -p "$out"
        echo '{"CN":"${prefix} CA","key":{"algo":"ecdsa","size":256}}' > csr.json
        cfssl gencert -initca csr.json | cfssljson -bare ca
        mv ca.pem "$out/crt"
        mv ca-key.pem "$out/key"
      '';

  mkInlineCertDrv =
    name: cert:
    if cert.override != null then
      pkgs.runCommand "${prefix}-${name}-inline" { } ''
        mkdir -p "$out"
        cp ${lib.escapeShellArg cert.override.crt} "$out/crt"
        cp ${lib.escapeShellArg cert.override.key} "$out/key"
      ''
    else
      pkgs.runCommand "${prefix}-${name}-inline" { nativeBuildInputs = [ pkgs.cfssl ]; } ''
        mkdir -p "$out"
        cfssl gencert \
          -ca ${inlineCaDrv}/crt \
          -ca-key ${inlineCaDrv}/key \
          -config ${signingConfigFile} \
          -profile ${cert.profile} \
          ${mkCsrFile "${prefix}-${name}" cert} | cfssljson -bare cert
        mv cert.pem "$out/crt"
        mv cert-key.pem "$out/key"
      '';

  caGenerator =
    if cfg.pki.ca.override != null then
      {
        share = true;
        files."crt".secret = false;
        files."key" = {
          secret = true;
          deploy = false;
        };
        script = copyOverride cfg.pki.ca.override;
      }
    else
      {
        share = true;

        prompts."ca-crt" = {
          description = "Cluster CA certificate (PEM)";
          type = "multiline";
        };
        prompts."ca-key" = {
          description = "Cluster CA private key (PEM)";
          type = "multiline-hidden";
        };

        files."crt".secret = false;
        files."key" = {
          secret = true;
          deploy = false;
        };

        script = ''
          set -euo pipefail
          cp "$prompts/ca-crt" "$out/crt"
          cp "$prompts/ca-key" "$out/key"
        '';
      };
in
{
  ###### interface

  options.cluster.cairn.pki = {
    certValidityDays = lib.mkOption {
      type = lib.types.int;
      default = 3650;
      description = "Validity period for generated certificates in days.";
    };

    generatorPrefix = lib.mkOption {
      type = lib.types.str;
      default = "cairn";
      description = ''
        Prefix used for clan var generator names (e.g. "<prefix>-ca",
        "<prefix>-<name>"). Override to match pre-existing generator names
        when migrating an existing cluster's PKI trust onto cairn, so
        already-provisioned CA/cert material is reused instead of
        regenerated.
      '';
    };

    inline = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Generate the CA and all certs as plain build-time Nix derivations
        instead of registering clan vars generators. Keys land in the Nix
        store world-readable, so this is only appropriate for throwaway
        test/VM clusters, never for a real deployment: it exists to avoid
        clan's vars/generator machinery, which requires
        allow-import-from-derivation during nixosTest evaluation.
      '';
    };

    certs = lib.mkOption {
      default = { };
      description = "Certificate definitions; each entry produces a clan var generator named <generatorPrefix>-<name>.";
      type = lib.types.attrsOf (
        lib.types.submodule (
          { name, config, ... }: {
            options = {
              cn = lib.mkOption {
                type = lib.types.str;
                description = "Certificate CN.";
              };
              org = lib.mkOption {
                type = lib.types.nullOr lib.types.str;
                default = null;
                description = "Certificate O field (organization).";
              };
              hosts = lib.mkOption {
                type = lib.types.listOf lib.types.str;
                default = [ ];
                description = "SANs; cfssl auto-detects IP vs DNS.";
              };
              profile = lib.mkOption {
                type = lib.types.enum [
                  "server"
                  "client"
                  "peer"
                ];
                description = "cfssl signing profile.";
              };
              owner = lib.mkOption {
                type = lib.types.str;
                description = "Owner of the private key file.";
              };
              share = lib.mkOption {
                type = lib.types.bool;
                default = true;
                description = "Shared across machines (true) or per-machine (false).";
              };
              override = lib.mkOption {
                type = lib.types.nullOr (
                  lib.types.submodule {
                    options = {
                      crt = lib.mkOption {
                        type = lib.types.str;
                        description = "Filesystem path to a pre-existing certificate (PEM) to seed this generator with, in place of signing a new one.";
                      };
                      key = lib.mkOption {
                        type = lib.types.str;
                        description = "Filesystem path to a pre-existing private key (PEM) to seed this generator with, in place of signing a new one.";
                      };
                    };
                  }
                );
                default = null;
                description = ''
                  Bring-your-own cert/key material for this generator, e.g. when
                  migrating pre-existing certificates onto cairn. When set, no CA
                  signing occurs; the given files are copied in as-is.

                  Paths are resolved at `clan vars generate` time on the invoking
                  machine and are never copied into the Nix store.
                '';
              };
              cert = lib.mkOption {
                type = lib.types.str;
                readOnly = true;
                description = "Resolved path to the certificate file.";
              };
              key = lib.mkOption {
                type = lib.types.str;
                readOnly = true;
                description = "Resolved path to the private key file.";
              };
            };

            config =
              if cfg.pki.inline then
                let
                  cd = mkInlineCertDrv name config;
                in
                {
                  cert = "${cd}/crt";
                  key = "${cd}/key";
                }
              else
                {
                  cert = topConfig.clan.core.vars.generators."${prefix}-${name}".files."crt".path;
                  key = topConfig.clan.core.vars.generators."${prefix}-${name}".files."key".path;
                };
          }
        )
      );
    };

    ca.cert = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      description = "Resolved path to the CA certificate.";
    };

    ca.override = lib.mkOption {
      type = lib.types.nullOr (
        lib.types.submodule {
          options = {
            crt = lib.mkOption {
              type = lib.types.str;
              description = "Filesystem path to a pre-existing CA certificate (PEM) to seed the CA generator with.";
            };
            key = lib.mkOption {
              type = lib.types.str;
              description = "Filesystem path to a pre-existing CA private key (PEM) to seed the CA generator with.";
            };
          };
        }
      );
      default = null;
      description = ''
        Bring-your-own CA cert/key material, e.g. when migrating an existing
        cluster's trust onto cairn. When set, the CA generator copies these
        files in directly instead of prompting for `ca-crt`/`ca-key`.

        Paths are resolved at `clan vars generate` time on the invoking
        machine and are never copied into the Nix store.
      '';
    };
  };

  ###### implementation

  config = {
    clan.core.vars.generators = lib.mkIf (!cfg.pki.inline) (
      {
        "${prefix}-ca" = caGenerator;
      }
      // lib.mapAttrs' (
        name: cert: lib.nameValuePair "${prefix}-${name}" (mkGenerator name cert)
      ) cfg.pki.certs
    );

    cluster.cairn.pki.ca.cert =
      if cfg.pki.inline then
        "${inlineCaDrv}/crt"
      else
        topConfig.clan.core.vars.generators."${prefix}-ca".files."crt".path;
  };
}
