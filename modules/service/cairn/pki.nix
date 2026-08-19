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
      -ca "$in/cairn-ca/crt" \
      -ca-key "$in/cairn-ca/key" \
      -config ${signingConfigFile} \
      -profile ${profile} \
      ${csrFile} | cfssljson -bare cert
    mv cert.pem "$out/crt"
    mv cert-key.pem "$out/key"
    rm -f cert.csr
  '';

  mkGenerator = name: cert: {
    inherit (cert) share;
    runtimeInputs = [ pkgs.cfssl ];
    dependencies = [ "cairn-ca" ];
    files."crt".secret = false;
    files."key" = {
      secret = true;
      owner = cert.owner;
    };
    script = gencert cert.profile (mkCsrFile "cairn-${name}" cert);
  };

  caGenerator = {
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

    certs = lib.mkOption {
      default = { };
      description = "Certificate definitions; each entry produces a clan var generator named cairn-<name>.";
      type = lib.types.attrsOf (
        lib.types.submodule (
          { name, ... }: {
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

            config = {
              cert = topConfig.clan.core.vars.generators."cairn-${name}".files."crt".path;
              key = topConfig.clan.core.vars.generators."cairn-${name}".files."key".path;
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
  };

  ###### implementation

  config = {
    clan.core.vars.generators = {
      "cairn-ca" = caGenerator;
    }
    // lib.mapAttrs' (
      name: cert: lib.nameValuePair "cairn-${name}" (mkGenerator name cert)
    ) cfg.pki.certs;

    cluster.cairn.pki.ca.cert = topConfig.clan.core.vars.generators."cairn-ca".files."crt".path;
  };
}
