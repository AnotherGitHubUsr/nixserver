{ config, pkgs, lib, ... }:
# ==============================================================================
# monitoring.nix — monctl scheduler + helper task timers
# ------------------------------------------------------------------------------
# Primary mechanism:
#   - monctl runs every 5 minutes, maintains persistent on-minutes counters,
#     and spawns task scripts as transient units when due.
# Tool resolution:
#   - Prefer explicit paths from ./scripts.nix (scripts.paths.*)
#   - Fallback: PATH via `/usr/bin/env <tool>` if scripts.nix is unavailable
# ==============================================================================

let
  scripts = import ./scripts.nix { inherit pkgs; };

  # helper: resolve a tool to either a store path or PATH fallback
  env = "${pkgs.coreutils}/bin/env";
  binOf = name: (scripts.paths.${name} or "${env} ${name}");
in
{
  ###############################################
  ## monctl scheduler
  ###############################################
  systemd.services."monctl" = {
    description = "Monitoring scheduler (monctl)";
    serviceConfig = {
      Type = "oneshot";
      # monctl decides what to run; use low priority and confined writes
      Nice = 10;
      IOSchedulingClass = "idle";
      ReadWritePaths = [ "/srv/nixserver/state/monitoring" ];
      NoNewPrivileges = true;
      PrivateTmp = true;
    };
    # Important: call monctl from the resolved path
    script = ''${binOf "monctl"} run'';
  };

  systemd.timers."monctl" = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*:0/5";     # every 5 minutes
      Persistent = true;
      RandomizedDelaySec = "30s";
    };
  };

  ###############################################
  ## Optional direct timers (monctl also covers these)
  ###############################################

  # Daily firewall snapshot
  systemd.services."monitoring-firewall-snapshot" = {
    description = "Snapshot nftables ruleset (daily)";
    serviceConfig = { Type = "oneshot"; };
    script = ''${binOf "monitoring-firewall-check"}'';
  };
  systemd.timers."monitoring-firewall-snapshot" = {
    wantedBy = [ "timers.target" ];
    timerConfig = { OnCalendar = "daily"; Persistent = true; };
  };

  # Daily bcachefs flush window at 11:00
  systemd.services."bcachefs-flush-window" = {
    description = "bcachefs writeback flush window (11:00)";
    serviceConfig = { Type = "oneshot"; };
    script = ''${binOf "bcachefs-writeback-flush-window"}'';
  };
  systemd.timers."bcachefs-flush-window" = {
    wantedBy = [ "timers.target" ];
    timerConfig = { OnCalendar = "11:00"; Persistent = true; };
  };

  # Clumped Nix store GC: after switch and daily
  systemd.services."nix-store-clumpgc" = {
    description = "Nix store clumped GC";
    serviceConfig = { Type = "oneshot"; };
    script = ''${binOf "nix-store-clumpgc"}'';
    wantedBy = [ "multi-user.target" ];
  };
  systemd.timers."nix-store-clumpgc-daily" = {
    wantedBy = [ "timers.target" ];
    timerConfig = { OnCalendar = "daily"; Persistent = true; };
  };
}
