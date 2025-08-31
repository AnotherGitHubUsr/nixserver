#!/usr/bin/env bash
# ==============================================================================
# monctl.sh  —  minute-counter–driven scheduler for monitoring + bcachefs tasks
# ------------------------------------------------------------------------------
# Purpose
#   Single scheduling wrapper that decides *what to run now* based on a persistent
#   minute counter, anchored to SMART Power_On_Hours for /dev/disk/by-label/weatherwax.
#   It launches tasks as isolated transient systemd units and records attempts/successes.
#
# Usage
#   monctl.sh run                        # evaluate schedule, spawn due tasks, update counters
#   monctl.sh status                     # dump counters and schedule with last-run metadata
#   monctl.sh force  <task>              # run a task immediately (ignore schedule)
#   monctl.sh record <task>              # mark a task successful "now" without running it
#
# Installation (suggested)
#   - Place at: /srv/nixserver/config/tools/monctl.sh
#   - Package via pkgs.writeShellApplication for immutable PATH entry.
#   - Drive with a single timer (don’t wake system from sleep):
#       [Unit]
#       Description=Monitoring scheduler (monctl)
#       [Service]
#       Type=oneshot
#       ExecStart=/nix/store/.../bin/monctl.sh run
#       [Timer]
#       OnBootSec=2m
#       OnUnitActiveSec=15m
#       RandomizedDelaySec=60s
#       Persistent=true
#       WakeSystem=no
#
# Files & State
#   - Task scripts: /srv/nixserver/config/tools/monitoring/*.sh
#   - State dir   : /srv/nixserver/state/monitoring
#       counters.json  → {on_minutes, last_monotonic_s, last_boot_id, last_smart_hours, last_update}
#       schedule.json  → {"tasks":{...},"runs":{...}} (per-task config + last run metadata)
#       logs/*.log     → per-task stdout/err (from transient units)
#
# Security model
#   - Transient units use DynamicUser, ProtectSystem=strict, ProtectHome=read-only,
#     and limit write access to /srv/nixserver/state/monitoring only.
#   - Scheduler itself holds no long-lived privileges and exits quickly.
# ==============================================================================

set -euo pipefail

# ----------------------------- paths (edit if needed) -------------------------
TOOLS_DIR="/srv/nixserver/config/tools/monitoring" # where task scripts live
STATE_DIR="/srv/nixserver/state/monitoring"        # persistent state
COUNTERS_JSON="$STATE_DIR/counters.json"           # minute counter + SMART anchor
SCHEDULE_JSON="$STATE_DIR/schedule.json"           # task config + run metadata
LOG_DIR="$STATE_DIR/logs"                          # per-task logs
LOCK="/run/lock/monctl.lock"                       # scheduler mutex

# Ensure required directories exist
mkdir -p "$TOOLS_DIR" "$STATE_DIR" "$LOG_DIR"

# ----------------------------- small utilities --------------------------------
need() { command -v "$1" >/dev/null || {
  echo "[ERR] missing $1. Try: nix shell nixpkgs#$1" >&2
  exit 2
}; }
need jq
need date
need awk
# smartctl is used; if absent we degrade gracefully (anchor stays at previous value)
command -v smartctl >/dev/null || echo "[monctl] smartctl not found; SMART anchor disabled" >&2

# Read helper for jq expressions (kept simple; return empty on error)
jq_read() { jq -r "$1" 2>/dev/null || true; }

# Correct atomic JSON write helper (first param = path; second param = JSON text)
json_write_atomic() {
  local path="$1"
  shift
  local tmp="${path}.new"
  umask 077 # ensure private state files
  printf '%s' "$1" >"$tmp"
  mv -f "$tmp" "$path"
}

# ----------------------------- counters: update logic -------------------------
# Updates counters.json using:
#   - Monotonic uptime (/proc/uptime) to accumulate minute-level progress
#   - Current boot ID to detect reboot and avoid time going backwards
#   - SMART Power_On_Hours as a non-decreasing floor + fast-forward
#
# Rules:
#   on_minutes := max( last.on_minutes + clamp(delta_min, 0..30), SMART_hours*60 )
#   Never decrement on_minutes. If SMART drops (device quirk), ignore.
update_counters() {
  local now_boot now_mono last_boot last_mono last_on last_smart smart_h on_min delta_min

  # Gather current boot-id and monotonic seconds; fall back to sane defaults
  now_boot="$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || echo unknown)"
  now_mono="$(awk '{print int($1)}' /proc/uptime 2>/dev/null || echo 0)"

  # Load previous state if present
  if [[ -s "$COUNTERS_JSON" ]]; then
    last_boot="$(jq_read '.last_boot_id // "unknown"' "$COUNTERS_JSON")"
    last_mono="$(jq_read '.last_monotonic_s // 0' "$COUNTERS_JSON")"
    last_on="$(jq_read '.on_minutes // 0' "$COUNTERS_JSON")"
    last_smart="$(jq_read '.last_smart_hours // 0' "$COUNTERS_JSON")"
  else
    last_boot="unknown"
    last_mono=0
    last_on=0
    last_smart=0
  fi

  # Base delta from monotonic uptime; on reboot treat now_mono as "since boot"
  if [[ "$now_boot" == "$last_boot" ]]; then
    delta_min=$(((now_mono - last_mono) / 60))
    ((delta_min < 0)) && delta_min=0
  else
    delta_min=$((now_mono / 60))
  fi
  # Safety cap to avoid runaway advance if scheduler paused for a long time
  ((delta_min > 30)) && delta_min=30
  on_min=$((last_on + delta_min))

  # SMART anchor for Weatherwax; avoid spinning disks with -n standby where possible
  smart_h="$(smartctl -n standby -A /dev/disk/by-label/weatherwax 2>/dev/null | awk '/Power_On_Hours/ {print $10; exit}')"
  [[ -n "${smart_h:-}" ]] || smart_h=$last_smart
  [[ "$smart_h" =~ ^[0-9]+$ ]] || smart_h=$last_smart

  # Fast-forward or keep as-is; never decrease due to SMART quirks
  if ((smart_h >= last_smart)); then
    local smart_min=$((smart_h * 60))
    ((smart_min > on_min)) && on_min=$smart_min
    last_smart=$smart_h
  fi

  # Persist atomically
  json_write_atomic "$COUNTERS_JSON" "$(jq -n \
    --arg boot "$now_boot" \
    --argjson mono "$now_mono" \
    --argjson on "$on_min" \
    --argjson smarth "$last_smart" \
    --arg now "$(date -Is)" \
    '{last_boot_id:$boot,last_monotonic_s:$mono,on_minutes:$on,last_smart_hours:$smarth,last_update:$now}')"
}

# ----------------------------- schedule: defaults -----------------------------
# Create a default schedule.json if missing. You can edit this file by hand.
ensure_schedule() {
  if [[ ! -s "$SCHEDULE_JSON" ]]; then
    umask 077
    cat >"$SCHEDULE_JSON" <<'JSON'
{
  "tasks": {
    "smart-monday":   {"enabled": true, "interval_min": 10080, "script": "monitoring-monday-smart.sh",          "timeout_sec": 1200},
    "periodic-8h":    {"enabled": true, "interval_min": 480,   "script": "monitoring-periodic-8h.sh",           "timeout_sec": 900},
    "firewall-snap":  {"enabled": true, "interval_min": 480,   "script": "monitoring-firewall-check.sh",        "timeout_sec": 120},
    "onhours-check":  {"enabled": true, "interval_min": 60,    "script": "monitoring-onhours-check.sh",         "timeout_sec": 120},
    "bcfs-threshold": {"enabled": true, "interval_min": 15,    "script": "bcachefs-writeback-threshold-watch.sh","timeout_sec": 300},
    "bcfs-verify":    {"enabled": true, "calendar": "03:00",   "script": "bcachefs-verify-reads.sh",            "timeout_sec": 21600},
    "bcfs-flush":     {"enabled": true, "calendar": "11:00",   "script": "bcachefs-writeback-flush-window.sh",  "timeout_sec": 10800}
  },
  "runs": { }
}
JSON
  fi
}

# ----------------------------- time window helper -----------------------------
# Accept tasks gated by local "HH:MM" calendar. Window = ±30 minutes, circular over midnight.
calendar_ok() {
  local hhmm="$1"
  local now_h now_m tgt_h tgt_m now_min tgt_min diff
  IFS=: read -r tgt_h tgt_m <<<"$hhmm"
  now_h="$(date +%H)"
  now_m="$(date +%M)"
  now_min=$((10#$now_h * 60 + 10#$now_m))
  tgt_min=$((10#$tgt_h * 60 + 10#$tgt_m))
  # circular absolute difference on a 1440-minute clock
  diff=$((now_min - tgt_min))
  ((diff < 0)) && diff=$((-diff))
  ((diff = diff < (1440 - diff) ? diff : (1440 - diff)))
  ((diff <= 30))
}

# ----------------------------- task launcher ----------------------------------
# Launch task in an isolated transient unit using systemd-run when available.
# Falls back to local background process with ionice/nice/timeout.
launch_task() {
  local name="$1" script_rel="$2" timeout="$3"
  local script="$TOOLS_DIR/$script_rel"
  [[ -x "$script" ]] || {
    echo "[monctl] missing or non-executable: $script" >&2
    return 1
  }

  if command -v systemd-run >/dev/null 2>&1; then
    # --collect cleans up the transient unit after it exits
    systemd-run --collect --quiet \
      --unit="mon-task@${name}" \
      -p DynamicUser=yes \
      -p ProtectSystem=strict \
      -p ProtectHome=read-only \
      -p ReadWritePaths="$STATE_DIR" \
      -p NoNewPrivileges=yes \
      -p PrivateTmp=yes \
      -p Nice=10 \
      -p IOSchedulingClass=idle \
      -- /bin/sh -c "timeout ${timeout}s '$script' >>'$LOG_DIR/${name}.log' 2>&1"
  else
    # Fallback: still non-blocking and gentle on I/O/CPU
    (ionice -c3 nice -n 10 timeout "${timeout}s" "$script" >>"$LOG_DIR/${name}.log" 2>&1) &
  fi
}

# ----------------------------- run metadata -----------------------------------
# These functions only update schedule.json; they do not affect counters.json.
mark_attempt() {
  local name="$1"
  local now onm
  now="$(date -Is)"
  onm="$(jq_read '.on_minutes' "$COUNTERS_JSON")"
  json_write_atomic "$SCHEDULE_JSON" "$(jq --arg n "$name" --arg now "$now" --argjson onm "${onm:-0}" '
    .runs[$n].last_attempt = $now | .runs[$n].last_attempt_on_min = $onm
  ' "$SCHEDULE_JSON")"
}

mark_success() {
  local name="$1"
  local now onm
  now="$(date -Is)"
  onm="$(jq_read '.on_minutes' "$COUNTERS_JSON")"
  json_write_atomic "$SCHEDULE_JSON" "$(jq --arg n "$name" --arg now "$now" --argjson onm "${onm:-0}" '
    .runs[$n].last_success = $now | .runs[$n].last_success_on_min = $onm
  ' "$SCHEDULE_JSON")"
}

# ----------------------------- main operations --------------------------------
do_run() {
  # Global lock so overlapping timers or manual invocations do not interleave
  exec 9>"$LOCK"
  flock -n 9 || {
    echo "[monctl] scheduler already running"
    exit 0
  }

  ensure_schedule
  update_counters

  local onm interval script enabled timeout cal last_success_on
  onm="$(jq_read '.on_minutes' "$COUNTERS_JSON")"

  # Iterate tasks as TSV rows to avoid subshell-quoting issues
  jq -r '.tasks | to_entries[] | "\(.key)\t\(.value.enabled)\t\(.value.interval_min // "null")\t\(.value.calendar // "null")\t\(.value.script)\t\(.value.timeout_sec // 600)"' \
    "$SCHEDULE_JSON" |
    while IFS=$'\t' read -r name enabled interval cal script timeout; do
      [[ "$enabled" == "true" ]] || continue

      # Next due by interval
      # shellcheck disable=SC2016  # $n is a jq var, not a shell var
      last_success_on="$(jq_read --arg n "$name" '.runs[$n].last_success_on_min // 0' "$SCHEDULE_JSON")"
      [[ -z "$last_success_on" ]] && last_success_on=0
      local due_by_interval=0
      if [[ "$interval" != "null" ]]; then
        local next_due=$((last_success_on + interval))
        ((onm >= next_due)) && due_by_interval=1 || due_by_interval=0
      fi

      # Calendar gate if present
      local cal_ok=1
      if [[ "$cal" != "null" ]]; then
        calendar_ok "$cal" && cal_ok=1 || cal_ok=0
      fi

      # Fire if interval says yes and calendar passes
      # Or if "calendar-only" task has never succeeded yet (bootstrap)
      if (((due_by_interval == 1) && (cal_ok == 1))) ||
        { [[ "$interval" == "null" ]] && ((cal_ok == 1)) && ((last_success_on == 0)); }; then
        echo "[monctl] due: $name (on_min=$onm, interval=$interval, cal=$cal)"
        mark_attempt "$name"
        launch_task "$name" "$script" "$timeout" || true
      fi
    done
}

do_status() {
  ensure_schedule
  # update_counters is cheap; refresh before showing status
  if [[ -s "$COUNTERS_JSON" ]]; then update_counters; fi
  echo "=== counters ==="
  jq . "$COUNTERS_JSON" 2>/dev/null || echo "{}"
  echo
  echo "=== schedule ==="
  jq . "$SCHEDULE_JSON"
}

do_force() {
  local name="${1:-}"
  [[ -n "$name" ]] || {
    echo "usage: monctl.sh force <task>" >&2
    exit 2
  }
  ensure_schedule
  update_counters

  # Lookup task row; fail if missing
  local row
  row="$(jq -r --arg n "$name" '.tasks[$n] | "\($n)\t\(.enabled)\t\(.script)\t\(.timeout_sec // 600)"' "$SCHEDULE_JSON" 2>/dev/null || true)"
  [[ -n "$row" && "$row" != "null" ]] || {
    echo "[monctl] no such task: $name" >&2
    exit 2
  }

  IFS=$'\t' read -r _ enabled script timeout <<<"$row"
  [[ "$enabled" == "true" ]] || echo "[monctl] warning: forcing disabled task $name" >&2
  mark_attempt "$name"
  launch_task "$name" "$script" "$timeout"
}

do_record() {
  local name="${1:-}"
  [[ -n "$name" ]] || {
    echo "usage: monctl.sh record <task>" >&2
    exit 2
  }
  ensure_schedule
  update_counters
  mark_success "$name"
  echo "[monctl] recorded success for $name"
}

# ----------------------------- command dispatch -------------------------------
case "${1:-run}" in
run) do_run ;;
status) do_status ;;
force)
  shift
  do_force "${1:-}"
  ;;
record)
  shift
  do_record "${1:-}"
  ;;
*)
  echo "usage: monctl.sh {run|status|force <task>|record <task>}" >&2
  exit 2
  ;;
esac
