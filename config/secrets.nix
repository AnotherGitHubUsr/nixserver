{ config, lib, pkgs
, secretsMap ? null       # parsed map from flake (preferred)
, manifestsPath ? null    # store path to /srv/nixserver/manifests (fallback source)
, ...
}:
# ==============================================================================
# secrets.nix — Agenix integration driven by the secrets map
# ------------------------------------------------------------------------------
# Contract:
#   - Consumes `secretsMap` from flake.specialArgs. If absent, falls back to
#     `${manifestsPath}/secrets-map.json` (store path input).
#   - Declares ALL entries from the map under `age.secrets` so Agenix will emit
#     `/run/agenix/<name>` for every blob.
#
# Tools:
#   - Prefer absolute tool path from ./scripts.nix (scripts.paths.secretsctl).
#   - Fallback to `secretsctl` on PATH for the unit. No global PATH pollution.
#
# Notable paths:
#   - Device AGE identity: /etc/agenix/key.txt
#   - Encrypted blobs:     /var/lib/agenix/<name>.age
#   - Decrypted at runtime: /run/agenix/<name>
# ==============================================================================

let
  scripts = import ./scripts.nix { inherit pkgs; };

  # Prefer absolute store path from scripts.nix; else rely on PATH
  secretsctlBin =
    let p = (scripts.paths."secretsctl" or null);
    in if p != null then p else "secretsctl";

  # Effective map: prefer injected `secretsMap`; else read from manifestsPath
  inherit (builtins) pathExists readFile fromJSON toPath;
  mapFromManifests =
    let p = if manifestsPath == null then null else toPath "${manifestsPath}/secrets-map.json";
    in if p != null && pathExists p then fromJSON (readFile p) else null;

  effMap =
    if secretsMap != null then secretsMap
    else if mapFromManifests != null then mapFromManifests
    else { version = 1; secrets = {}; };

  # Minimal shape check
  _ = if effMap ? version && effMap ? secrets then true
      else throw "secrets.nix: effective secrets map is missing `version` or `secrets` keys";
in
{
  options.services.secretsctl.enable = lib.mkOption {
    type = lib.types.bool;
    default = true;
    description = "Enable secretsctl verification unit; does not add tools to global PATH.";
  };

  config = {
    # Use the standard on-host identity for Agenix
    age.identityPaths = [ "/etc/agenix/key.txt" ];

    # Declare every secret from the map so Agenix materializes /run/agenix/<name>.
    age.secrets =
      lib.mapAttrs
        (_name: spec: {
          file  = spec.agePath;
          mode  = (spec.mode  or "0400");
          owner = (spec.owner or "root");
          group = (spec.group or "root");
        })
        (effMap.secrets or {});

    # Ensure Agenix-related directories exist
    systemd.tmpfiles.rules = [
      "d /etc/agenix 0700 root root - -"
      "d /var/lib/agenix 0700 root root - -"
    ];

    # Non-interactive smoke-check: fail if any blob isn’t decryptable by on-host identities.
    systemd.services.secretsctl-check = lib.mkIf config.services.secretsctl.enable {
      description = "Verify encrypted secrets with any on-host AGE identity (non-interactive)";
      wantedBy = [ "multi-user.target" ];
      after = [ "local-fs.target" "systemd-tmpfiles-setup.service" "agenix.service" ];
      requires = [ "agenix.service" ];
      serviceConfig.Type = "oneshot";
      environment.AGE_IDENTITIES = lib.mkDefault "";
      script = ''exec ${secretsctlBin} check --any --fail-fast'';
    };
  };
}
