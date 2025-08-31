{ config, lib, pkgs, ... }:
# ==============================================================================
# secrets.nix — Agenix integration using a host-local JSON map
# ------------------------------------------------------------------------------
# Data contract
#   - secretsMap is passed by the flake as a JSON object: name → { agePath, mode?, owner?, group? }
#   - At activation, Agenix decrypts each entry to /run/agenix/<name>
# Tools
#   - Prefer ./scripts.nix paths for `secretsctl`; fallback to PATH if missing.
# ==============================================================================

let
  scripts = import ./scripts.nix { inherit pkgs; };
  env = "${pkgs.coreutils}/bin/env";
  secretsctlBin = (scripts.paths."secretsctl" or "${env} secretsctl");
in
{
  options.services.secretsctl.enable = lib.mkOption {
    type = lib.types.bool;
    default = true;
    description = "Install secretsctl tool for local secret map management.";
  };

  config = {
    # Expose secretsctl on PATH as a backup even when scripts.paths is used elsewhere
    environment.systemPackages = lib.mkIf config.services.secretsctl.enable [ (import ./scripts.nix { inherit pkgs; }).secretsCtl ];

    # Ensure Agenix directories exist
    systemd.tmpfiles.rules = [
      "d /etc/agenix 0700 root root - -"
      "d /var/lib/agenix 0700 root root - -"
    ];

    # Optional smoke-check service: verifies blobs decryptable with current identities
    systemd.services."secretsctl-check" = lib.mkIf config.services.secretsctl.enable {
      description = "Verify encrypted secret blobs against available identities";
      serviceConfig = { Type = "oneshot"; };
      script = ''${secretsctlBin} check || true'';
      wantedBy = [ "multi-user.target" ];
    };
  };
}
