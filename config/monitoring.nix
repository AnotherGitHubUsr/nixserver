{ pkgs, lib, ... }:
# monitoring.nix
# Units & timers for maintenance and monitoring. Relies on scripts.nix wrappers.
let
  scripts = import ./scripts.nix { inherit pkgs; };
in
{
  #### Nix store clumped garbage collection (daily) ####
{ pkgs, lib, ... }:
let scripts = import ./scripts.nix { inherit pkgs; };
in {

  # Run clumped GC once right after every successful switch
  system.activationScripts.gcOnSwitch.text = ''
    ${pkgs.systemd}/bin/systemctl --no-block start nix-store-clumpgc.service
  '';

  systemd.services."nix-store-clumpgc" = {
    description = "Nix store clumped garbage collection";
    documentation = [ "man:nix-store(1)" ];
    serviceConfig = {
      Type = "oneshot";
      # Ensure our /srv state path exists (we don't use StateDirectory=/var/lib).
      ExecStartPre = "${pkgs.coreutils}/bin/install -d -m 0750 /srv/nixserver/state/gc";
      ExecStart = "${scripts.paths."nix-store-clumpgc"}";
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
    };
  };
}


  #### bcachefs writeback daily flush window at 11:00 ####
  systemd.services."bcachefs-flush-window" = {
    description = "bcachefs writeback flush window";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = lib.getExe pkgs.bash + ''
        -c '${scripts.paths."bcachefs-writeback-window"}'
      '';
      Environment = [
        "ACTION=open"
        "BYTES_OPEN=268435456"   # ~256 MiB
      ];
      ExecStartPost = lib.getExe pkgs.bash + ''
        -c 'sleep ${toString 7200}; ACTION=close ${scripts.paths."bcachefs-writeback-window"}'
      '';
    };
  };
  systemd.timers."bcachefs-flush-window" = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "11:00";
      Persistent = true;
    };
  };

  #### bcachefs threshold watcher (hourly) ####
  systemd.services."bcachefs-threshold-watch" = {
    description = "bcachefs dirty-bytes threshold watcher";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${scripts.paths."bcachefs-writeback-threshold"}";
    };
  };
  systemd.timers."bcachefs-threshold-watch" = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "hourly";
      Persistent = true;
    };
  };

  #### Periodic monitoring every 8 hours ####
  systemd.services."monitoring-periodic-8h" = {
    description = "Periodic monitoring bundle (8h)";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${scripts.paths."monitoring-periodic-8h"}";
    };
  };
  systemd.timers."monitoring-periodic-8h" = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "0/8:00:00";
      Persistent = true;
    };
  };

  #### Monday SMART + AV sweep at 10:30 ####
  systemd.services."monitoring-monday-1030" = {
    description = "Weekly SMART tests and AV sweep (Monday 10:30)";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${scripts.paths."monitoring-monday-smart"}";
    };
  };
  systemd.timers."monitoring-monday-1030" = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "Mon *-*-* 10:30:00";
      Persistent = true;
    };
  };

  #### Firewall snapshot (daily) ####
  systemd.services."monitoring-firewall-snapshot" = {
    description = "Snapshot nftables ruleset (daily)";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${scripts.paths."monitoring-firewall-check"}";
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
