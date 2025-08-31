{ pkgs, lib ? pkgs.lib }:
# ==============================================================================
# scripts.nix
# ------------------------------------------------------------------------------
# Purpose
#   Build reproducible helper binaries from ./tools using
#   pkgs.writeShellApplication. Sources are embedded at build time via
#   builtins.readFile. One active version per build, systemd-safe entrypoints.
#
# How to extend
#   - Add your script under ./tools or ./tools/monitoring
#   - Add a writeShellApplication here with appropriate runtimeInputs
#   - Reference it in the `paths` attrset for stable path exposure
#
# Policy
#   - No state in /etc. All state under /srv/nixserver/{state,manifests,releases}.
#   - Monitoring uses monctl + task scripts under ./tools/monitoring/.
#   - Prefer nixos-apply over raw nixos-rebuild for host switches.
# ==============================================================================

let
  mk = { name, runtimeInputs ? [ ], text }:
    pkgs.writeShellApplication {
      inherit name runtimeInputs;
      text = ''
        set -euo pipefail
        ${text}
      '';
    };

  # ---------------- Core host ops ----------------
  nixosApply = pkgs.writeShellApplication {
    name = "nixos-apply";
    runtimeInputs = with pkgs; [ nixos-rebuild rsync git coreutils systemd ];
    text = builtins.readFile ./tools/nixos-apply.sh;
  };

  exportRelease = pkgs.writeShellApplication {
    name = "export-release";
    runtimeInputs = with pkgs; [ rsync git nix coreutils ];
    text = builtins.readFile ./tools/export-release.sh;
  };

  gitAutocommitPush = pkgs.writeShellApplication {
    name = "git-autocommit-push";
    runtimeInputs = with pkgs; [ git openssh coreutils ];
    text = builtins.readFile ./tools/git-autocommit-push.sh;
  };

  healthReport = pkgs.writeShellApplication {
    name = "health-report";
    runtimeInputs = with pkgs; [ coreutils findutils ];
    text = builtins.readFile ./tools/health-report.sh;
  };

  lintScripts = pkgs.writeShellApplication {
    name = "lint-scripts";
    runtimeInputs = with pkgs; [ shellcheck shfmt findutils git coreutils ];
    text = builtins.readFile ./tools/lint-scripts.sh;
  };

  # ---------------- Disks ----------------
  diskConfigTool = pkgs.writeShellApplication {
    name = "disk-config-tool";
    runtimeInputs = with pkgs; [ util-linux gawk gnused gnugrep coreutils findutils jq python3 bcachefs-tools ];
    text = builtins.readFile ./tools/disk-config-tool.sh;
  };

  # ---------------- Secrets / Agenix ----------------
  secretsCtl = pkgs.writeShellApplication {
    name = "secretsctl";
    runtimeInputs = with pkgs; [
      age jq gnutar util-linux coreutils gnused gawk openssh openssl whois apacheHttpd systemd
    ];
    text = builtins.readFile ./tools/secretsctl;
  };

  # ---------------- Nix store GC policy ----------------
  nixStoreClumpGc = pkgs.writeShellApplication {
    name = "nix-store-clumpgc";
    runtimeInputs = with pkgs; [ python3 nix coreutils git jq ];
    text = ''
      set -euo pipefail
      exec ${./config/tools/nix-store-clumpgc.py} --apply --state /srv/nixserver/state/gc/state.json "$@"
    '';
  };

  # ---------------- Monitoring wrapper ----------------
  monctl = pkgs.writeShellApplication {
    name = "monctl";
    runtimeInputs = with pkgs; [ jq coreutils util-linux gawk systemd smartmontools ];
    text = builtins.readFile ./tools/monctl.sh;
  };

  # ---------------- Monitoring tasks ----------------
  mon_bcachefs_verify_reads = pkgs.writeShellApplication {
    name = "bcachefs-verify-reads";
    runtimeInputs = with pkgs; [ util-linux coreutils findutils gnugrep gnused gawk procps systemd ];
    text = builtins.readFile ./tools/monitoring/bcachefs-verify-reads.sh;
  };

  mon_bcachefs_writeback_threshold = pkgs.writeShellApplication {
    name = "bcachefs-writeback-threshold-watch";
    runtimeInputs = with pkgs; [ coreutils gawk findutils util-linux bcachefs-tools ];
    text = builtins.readFile ./tools/monitoring/bcachefs-writeback-threshold-watch.sh;
  };

  mon_bcachefs_flush_window = pkgs.writeShellApplication {
    name = "bcachefs-writeback-flush-window";
    runtimeInputs = with pkgs; [ systemd coreutils util-linux ];
    text = builtins.readFile ./tools/monitoring/bcachefs-writeback-flush-window.sh;
  };

  mon_monday_smart = pkgs.writeShellApplication {
    name = "monitoring-monday-smart";
    runtimeInputs = with pkgs; [ util-linux hdparm smartmontools findutils gnugrep clamav coreutils ];
    text = builtins.readFile ./tools/monitoring/monitoring-monday-smart.sh;
  };

  mon_periodic_8h = pkgs.writeShellApplication {
    name = "monitoring-periodic-8h";
    runtimeInputs = with pkgs; [ hdparm clamav systemd smartmontools lm_sensors gnugrep nftables coreutils ];
    text = builtins.readFile ./tools/monitoring/monitoring-periodic-8h.sh;
  };

  mon_firewall_check = pkgs.writeShellApplication {
    name = "monitoring-firewall-check";
    runtimeInputs = with pkgs; [ nftables coreutils systemd ];
    text = builtins.readFile ./tools/monitoring/monitoring-firewall-check.sh;
  };

  mon_onhours_check = pkgs.writeShellApplication {
    name = "monitoring-onhours-check";
    runtimeInputs = with pkgs; [ smartmontools bcachefs-tools e2fsprogs xfsprogs btrfs-progs coreutils util-linux findutils ];
    text = builtins.readFile ./tools/monitoring/monitoring-onhours-check.sh;
  };

in
rec {
  inherit
    nixosApply
    exportRelease
    gitAutocommitPush
    healthReport
    lintScripts
    diskConfigTool
    secretsCtl
    nixStoreClumpGc
    monctl
    mon_bcachefs_verify_reads
    mon_bcachefs_writeback_threshold
    mon_bcachefs_flush_window
    mon_monday_smart
    mon_periodic_8h
    mon_firewall_check
    mon_onhours_check;

  paths = {
    # Core ops
    "nixos-apply"                        = "${nixosApply}/bin/nixos-apply";
    "export-release"                     = "${exportRelease}/bin/export-release";
    "git-autocommit-push"                = "${gitAutocommitPush}/bin/git-autocommit-push";
    "health-report"                      = "${healthReport}/bin/health-report";
    "lint-scripts"                       = "${lintScripts}/bin/lint-scripts";

    # Disks
    "disk-config-tool"                   = "${diskConfigTool}/bin/disk-config-tool";

    # Secrets
    "secretsctl"                         = "${secretsCtl}/bin/secretsctl";

    # GC policy
    "nix-store-clumpgc"                  = "${nixStoreClumpGc}/bin/nix-store-clumpgc";

    # Monitoring wrapper + tasks
    "monctl"                             = "${monctl}/bin/monctl";
    "bcachefs-verify-reads"              = "${mon_bcachefs_verify_reads}/bin/bcachefs-verify-reads";
    "bcachefs-writeback-threshold"       = "${mon_bcachefs_writeback_threshold}/bin/bcachefs-writeback-threshold-watch";
    "bcachefs-writeback-flush-window"    = "${mon_bcachefs_flush_window}/bin/bcachefs-writeback-flush-window";
    "monitoring-monday-smart"            = "${mon_monday_smart}/bin/monitoring-monday-smart";
    "monitoring-periodic-8h"             = "${mon_periodic_8h}/bin/monitoring-periodic-8h";
    "monitoring-firewall-check"          = "${mon_firewall_check}/bin/monitoring-firewall-check";
    "monitoring-onhours-check"           = "${mon_onhours_check}/bin/monitoring-onhours-check";
  };
}
