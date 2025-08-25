{ config, pkgs, lib, scripts, ... }:
# ==============================================================================
# monitoring.nix — Maintenance & monitoring units for nixserver
# ==============================================================================
# PURPOSE
#   Define systemd services and timers that:
#     • Run a clumped Nix store GC after each switch and daily on a timer
#     • Open a daily bcachefs “flush window” (higher writeback bandwidth) at 11:00
#     • Watch dirty-bytes hourly and open a temporary flush window if above a threshold
#     • Run a periodic monitoring bundle every 8 hours
#     • Run a Monday 10:30 SMART + AV sweep
#     • Snapshot the firewall (nft ruleset) daily
#
# DEPENDENCIES
#   This module relies on helper scripts exported by ./scripts.nix via
#   `scripts.paths` (see scripts.nix). It expects the following paths to exist:
#     - "nix-store-clumpgc"
#     - "bcachefs-writeback-set"
#     - "bcachefs-writeback-threshold"
#     - "monitoring-periodic-8h"
#     - "monitoring-monday-smart"
#     - "monitoring-firewall-check"
#
# CONVENTIONS
#   • All operations that may touch /srv ensure the directory exists first.
#   • Timers are Persistent so missed runs are executed at boot.
#   • Services are oneshot and invoked by their timers or activation hooks.
# ==============================================================================
let
  scripts = import ./scripts.nix { inherit pkgs; };
  # Default flush window parameters
  flushBytes = 268435456;     # ~256 MiB in-flight writeback
  windowSec  = 7200;          # 2 hours
in
{
  ###############################################
  ## Nix store clumped garbage collection
  ###############################################

  # Kick off clumped GC after each successful switch
  /* system.activationScripts.gcOnSwitch.text = ''
    ${pkgs.systemd}/bin/systemctl --no-block start nix-store-clumpgc.service
  ''; */

  systemd.services."nix-store-clumpgc" = {
    description = "Nix store clumped garbage collection";
    documentation = [ "man:nix-store(1)" ];
    serviceConfig = {
      Type = "oneshot";
      # Ensure our /srv state path exists (we don't use StateDirectory=/var/lib).
      ExecStartPre = "${pkgs.coreutils}/bin/install -d -m 0750 /srv/nixserver/state/gc";
      ExecStart = scripts.paths."nix-store-clumpgc";
      Nice = 10;
      IOSchedulingClass = "best-effort";
      # If /srv is a separate mount, this prevents races:
      RequiresMountsFor = "/srv/nixserver/state";
    };
  };

  systemd.timers."nix-store-clumpgc" = {
    description = "Daily clumped GC";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "daily";
      Persistent = true;
      OnBootSec = "5min";
      RandomizedDelaySec = "1h";
    };
  };

  ###############################################
  ## bcachefs: daily flush window (open at 11:00)
  ###############################################

  systemd.services."bcachefs-flush-window" = {
    description = "bcachefs writeback flush window (open then close after ${toString windowSec}s)";
    serviceConfig = {
      Type = "oneshot";
      # Open the window: raise the in-flight writeback bytes
      ExecStart = "${pkgs.bash}/bin/bash -c '${scripts.paths."bcachefs-writeback-set"} ${toString flushBytes}'";
      # After ExecStart completes, sleep and then close the window
      ExecStartPost = "${pkgs.bash}/bin/bash -c 'sleep ${toString windowSec}; ${scripts.paths."bcachefs-writeback-set"} 0'";
    };
  };

  systemd.timers."bcachefs-flush-window" = {
    description = "Daily bcachefs writeback flush window at 11:00";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "11:00";
      Persistent = true;
    };
  };

  ###############################################
  ## bcachefs: threshold watcher (hourly)
  ###############################################
  systemd.services."bcachefs-threshold-watch" = {
    description = "bcachefs dirty-bytes threshold watcher";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = scripts.paths."bcachefs-writeback-threshold";
    };
  };
  systemd.timers."bcachefs-threshold-watch" = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "hourly";
      Persistent = true;
    };
  };

  ###############################################
  ## Periodic monitoring every 8 hours
  ###############################################
  systemd.services."monitoring-periodic-8h" = {
    description = "Periodic monitoring bundle (8h)";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = scripts.paths."monitoring-periodic-8h";
    };
  };
  systemd.timers."monitoring-periodic-8h" = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "0/8:00:00";
      Persistent = true;
    };
  };

  ###############################################
  ## Monday SMART + AV sweep at 10:30
  ###############################################
  systemd.services."monitoring-monday-1030" = {
    description = "Weekly SMART tests and AV sweep (Monday 10:30)";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = scripts.paths."monitoring-monday-smart";
    };
  };
  systemd.timers."monitoring-monday-1030" = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "Mon *-*-* 10:30:00";
      Persistent = true;
    };
  };

  ###############################################
  ## Daily firewall snapshot
  ###############################################
  systemd.services."monitoring-firewall-snapshot" = {
    description = "Snapshot nftables ruleset (daily)";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = scripts.paths."monitoring-firewall-check";
    };
  };
  systemd.timers."monitoring-firewall-snapshot" = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "daily";
      Persistent = true;
    };
  };
}
