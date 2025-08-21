# ==============================================================================
# disk.nix
# ------------------------------------------------------------------------------
# Purpose:
#   Consolidated boot + filesystem module. Filesystems are imported from a
#   machine-generated JSON file, and bcachefs writeback scheduling is handled
#   via immutable helpers from scripts.nix.
#
# Filesystems source:
#   - Reads ./generated/filesystems.json (built by:
#       ./disk-config-tool.sh --apply ./generated/disk-plan.current.toml
#     or:
#       ./gen-filesystems-from-current.sh       # generates TOML + JSON preview)
#
# IMPORTANT (user action):
#   - Keep /boot mounted when rebuilding so boot entries update:
#       sudo mount /boot
#       sudo nixos-rebuild switch --flake .# --install-bootloader
#
# Timers:
#   - Daily flush window at 11:00 (Persistent) → raises inflight, then drops.
#   - Threshold watcher every 15 min → opens flush when cached/dirty ≥ 150 GiB.
#   - Baseline at boot → inflight = 0.
# ==============================================================================

{ config, pkgs, lib, ... }:

let
  scripts = import ./scripts.nix { inherit pkgs lib; };

  # --- Filesystems input (machine-generated JSON) -----------------------------
  fsJsonPath = ./generated/filesystems.json;

  # If the JSON is missing, continue with an empty list (assert later that "/" exists).
  fsList =
    if builtins.pathExists fsJsonPath
    then builtins.fromJSON (builtins.readFile fsJsonPath)
    else [];

  # Convert list → attrset keyed by mountPoint.
  #
  # NOTE:
  # - Sanitize options: keep only non-empty strings.
  # - Do NOT emit an empty `options` attribute: some consumers expect a non-empty list
  #   and will error early if they see `[]` before later merges. We append "noatime"
  #   for "/" further below so it becomes non-empty.
  fsAttrset = builtins.listToAttrs (map (fs:
    let
      optsRaw = if fs ? options then fs.options else [];
      opts    = builtins.filter (o: builtins.isString o && o != "") optsRaw;
      device  = fs.device or "auto";
      fsType  = fs.fsType or "auto";
      base    = { inherit device fsType; };
      withOpt = base // lib.optionalAttrs (opts != []) { options = opts; };
    in {
      name  = fs.mountPoint;
      value = withOpt;
    }
  ) fsList);

in
lib.mkMerge [
  {
    # --- Sanity: require a root filesystem from the generated JSON ------------
    assertions = [
      {
        assertion = fsAttrset ? "/";
        message   = "generated/filesystems.json must define a root filesystem (mountPoint \"/\").\n\
                     Generate it with:\n\
                       ./disk-config-tool.sh --apply ./generated/disk-plan.current.toml\n\
                     or:\n\
                       ./gen-filesystems-from-current.sh";
      }
    ];

    # --- Boot & ESP (consolidated) -------------------------------------------
    boot.loader.systemd-boot.enable = true;
    boot.loader.efi.canTouchEfiVariables = true;

    # --- Mount declarations from generated JSON ------------------------------
    fileSystems = fsAttrset;

    # --- ESP safety helper ---------------------------------------------------
    systemd.services.ensure-boot-esp = {
      description = "Ensure ESP is mounted on /boot when present";
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = scripts.paths."ensure-boot-esp";
      };
    };

    # --- Baseline writeback throttle at boot --------------------------------
    systemd.services."bcachefs-writeback-baseline" = {
      description = "bcachefs writeback: baseline inflight = 0";
      wantedBy = [ "multi-user.target" ];
      after = [ "local-fs.target" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${scripts.paths."bcachefs-writeback-set"} 0";
      };
    };

    # --- Daily flush window at 11:00 ----------------------------------------
    systemd.services."bcachefs-writeback-daily" = {
      description = "bcachefs writeback: daily flush window";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = scripts.paths."bcachefs-writeback-schedule";
        Environment = [
          "BCACHEFS_MOVE_BYTES_FLUSH=268435456"   # ~256 MiB inflight
          "BCACHEFS_FLUSH_WINDOW_SECONDS=7200"    # 2 hours
        ];
      };
    };
    systemd.timers."bcachefs-writeback-daily" = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "11:00";
        Persistent = true;
      };
    };

    # --- Threshold watcher every 15 minutes ---------------------------------
    systemd.services."bcachefs-writeback-threshold" = {
      description = "bcachefs writeback: threshold-triggered flush";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = scripts.paths."bcachefs-writeback-threshold";
        Environment = [
          "BCACHEFS_DIRTY_LIMIT=161061273600"     # 150 GiB
          "BCACHEFS_MOVE_BYTES_FLUSH=268435456"
          "BCACHEFS_FLUSH_WINDOW_SECONDS=7200"
        ];
      };
    };
    systemd.timers."bcachefs-writeback-threshold" = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "10m";
        OnUnitActiveSec = "15m";
        AccuracySec = "1m";
        Persistent = true;
      };
    };
  }

  # --- Post-process mounts (only if entries exist) ---------------------------
  (lib.optionalAttrs (fsAttrset ? "/") {
    # Ensure a non-empty options list for root by appending "noatime".
    fileSystems."/".options = (fsAttrset."/".options or []) ++ [ "noatime" ];
  })

  (lib.optionalAttrs (fsAttrset ? "/boot") {
    # Keep /boot options as provided (no enforced extras here).
    fileSystems."/boot".options = (fsAttrset."/boot".options or []);
  })
]