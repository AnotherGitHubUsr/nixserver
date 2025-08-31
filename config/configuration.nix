# ==============================================================================
# configuration.nix — System entrypoint
# ------------------------------------------------------------------------------
# Imports modular configs and exposes helper tools from ./scripts.nix.
# Tools are added to PATH as a backup, but services/modules should prefer
# injecting explicit binaries from scripts.paths to avoid PATH ambiguity.
# ==============================================================================

{ config, pkgs, pkgsUnstable ? null, agenix, ... }:

let
  # Import reproducible helper tools
  scripts = import ./scripts.nix { inherit pkgs; };

  # Convenience: list of tool derivations to expose on PATH as a fallback
  toolsOnPath = with scripts; [
    nixosApply exportRelease gitAutocommitPush healthReport lintScripts
    diskConfigTool secretsCtl nixStoreClumpGc
    monctl
    mon_bcachefs_verify_reads mon_bcachefs_writeback_threshold mon_bcachefs_flush_window
    mon_monday_smart mon_periodic_8h mon_firewall_check mon_onhours_check
  ];
in
{
  imports = [
    ./network.nix
    ./security.nix
    ./kernel.nix
    ./pkgs.nix
    ./disk.nix
    ./secrets.nix
    ./monitoring.nix
    ./users.nix
  ];

  # Make tools available on PATH as a backup. Primary usage is via scripts.paths.
  environment.systemPackages = toolsOnPath;

  # Example: ensure flakes are enabled and set stateVersion
  nix.settings.experimental-features = [ "nix-command" "flakes" ];
  system.stateVersion = "25.05";
}
