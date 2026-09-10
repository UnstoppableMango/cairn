{
  config,
  lib,
  pkgs,
  ...
}:
let
  topConfig = config;
  cfg = config.cluster.cairn;

  expiry = "${toString (cfg.pki.certValidityDays * 24)}h";
  prefix = cfg.pki.generatorPrefix;

  signingConfigFile = pkgs.writeText "cfssl-signing-config.json" (
    builtins.toJSON {
      signing = {
        default = { inherit expiry; };
        profiles = lib.mapAttrs (_: usages: { inherit expiry usages; }) {
          server = [
            "digital signature"
            "server auth"
          ];
          client = [
            "digital signature"
            "client auth"
          ];
          peer = [
            "digital signature"
            "server auth"
            "client auth"
          ];
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
    { share, key }:
    rest:
    {
      inherit share;
      files."crt".secret = false;
      files."key" = {
        secret = true;
      }
      // key;
    }
    // rest;

  mkCertGenerator =
    name: cert:
    mkGenerator
      {
        inherit (cert) share;
        key.owner = cert.owner;
      }
      (
        if cert.override != null then
          { script = copyOverride cert.override; }
        else
          {
            runtimeInputs = [ pkgs.cfssl ];
            dependencies = [ "${prefix}-ca" ];
            script = gencert cert.profile (mkCsrFile "${prefix}-${name}" cert);
          }
      );

  caGenerator =
    mkGenerator
      {
        share = true;
        key.deploy = false;
      }
      (
        if cfg.pki.ca.override != null then
          { script = copyOverride cfg.pki.ca.override; }
        else
          {
            prompts."ca-crt" = {
              description = "Cluster CA certificate (PEM)";
              type = "multiline";
            };
            prompts."ca-key" = {
              description = "Cluster CA private key (PEM)";
              type = "multiline-hidden";
            };

            script = ''
              set -euo pipefail
              cp "$prompts/ca-crt" "$out/crt"
              cp "$prompts/ca-key" "$out/key"
            '';
          }
      );

  mkOverrideOption =
    subject:
    lib.mkOption {
      type = lib.types.nullOr (
        lib.types.submodule {
          options = {
            crt = lib.mkOption {
              type = lib.types.str;
              description = "Filesystem path to a pre-existing ${subject} certificate (PEM).";
            };
            key = lib.mkOption {
              type = lib.types.str;
              description = "Filesystem path to a pre-existing ${subject} private key (PEM).";
            };
          };
        }
      );
      default = null;
      description = ''
        Bring-your-own ${subject} cert/key material to seed this generator
        with, e.g. when migrating an existing cluster's certificates onto
        cairn. When set, no CA signing or prompting occurs; the given files
        are copied in as-is.

        Paths are resolved at `clan vars generate` time on the invoking
        machine and are never copied into the Nix store.
      '';
    };
in
{
  options.cluster.cairn.pki = (import ./options.nix { inherit lib; }) // {
    certs = lib.mkOption {
      default = { };
      description = "Certificate definitions; each entry produces a clan var generator named <generatorPrefix>-<name>.";
      type = lib.types.attrsOf (
        lib.types.submodule (
          { name, ... }:
          {
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
              override = mkOverrideOption "certificate";
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

    ca.override = mkOverrideOption "CA";
  };

  config = {
    clan.core.vars.generators = {
      "${prefix}-ca" = caGenerator;
    }
    // lib.mapAttrs' (
      name: cert: lib.nameValuePair "${prefix}-${name}" (mkCertGenerator name cert)
    ) cfg.pki.certs;

    cluster.cairn.pki.ca.cert = topConfig.clan.core.vars.generators."${prefix}-ca".files."crt".path;
  };
}
