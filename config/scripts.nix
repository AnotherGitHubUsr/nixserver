# ==============================================================================
# scripts.nix
# ------------------------------------------------------------------------------
# Reproducible helper binaries compiled into the Nix store using
# pkgs.writeShellApplication. These are systemd-safe, immutable entrypoints.
#
# Path & state policy (new layout):
#   - Eval-time JSON maps    → /srv/nixserver/manifests/*.json     (pure inputs)
#   - Runtime / human TOML   → /srv/nixserver/state/*.toml         (host-edited)
#   - Logs / reports         → /srv/nixserver/state/monitoring/*   (human-facing)
#   - Canonical secrets map  → /srv/nixserver/manifests/secrets-map.json
#   - /etc/nixos/.generated is deprecated; no state under /etc.
# ==============================================================================
{ pkgs, lib ? pkgs.lib }:
let
  mk = { name, runtimeInputs ? [ ], text }:
    pkgs.writeShellApplication {
      inherit name runtimeInputs;
      text = ''
        set -euo pipefail
        ${text}
      '';
    };

  # Makes the building work from anywhere.
  nixosApply = pkgs.writeShellApplication {
    name = "nixos-apply";
    runtimeInputs = with pkgs; [ nixos-rebuild rsync git coreutils systemd ];
    text = builtins.readFile ./tools/nixos-apply.sh;
  };
 
  # ---------- BCACHEFS: VERIFY READS (POOR MAN'S SCRUB) ----------
  # Warn-only integrity pass: remount ro,nochanges; stream-read all files; remount rw.
  bcachefsVerifyReads = mk {
    name = "bcachefs-verify-reads";
    runtimeInputs = with pkgs; [ util-linux coreutils findutils gnugrep gnused gawk procps systemd ];
    text = ''
      logdir="''${VERIFY_LOGDIR:-/srv/nixserver/state/monitoring/verify-reads}"
      mkdir -p "$logdir"

      # Targets list
      if [[ $# -gt 0 ]]; then
        targets=("$@")
      elif [[ -n "''${BCACHEFS_TARGETS:-}" ]]; then
        read -r -a targets <<< "''${BCACHEFS_TARGETS}"
      else
        mapfile -t targets < <(findmnt -rn -t bcachefs -o TARGET | sort -u)
      fi

      if [[ ''${#targets[@]} -eq 0 ]]; then
        echo "bcachefs-verify-reads: no bcachefs mounts found."
        exit 0
      fi

      for mnt in "''${targets[@]}"; do
        [[ -d "$mnt" ]] || { echo "skip: $mnt not a directory"; continue; }
        esc="''${mnt//[^A-Za-z0-9_.-]/_}"
        lock="/run/lock/verify-reads.''${esc}.lock"
        exec 9>"$lock"
        if ! flock -n 9; then
          echo "verify already running for $mnt"
          continue
        fi

        src="$(findmnt -nro SOURCE "$mnt")"
        [[ -n "$src" ]] || { echo "skip: cannot resolve source for $mnt"; continue; }

        echo "=== verify-reads start: $mnt (src=$src) ==="
        start="$(date -Is)"

        # Go super-RO (nochanges)
        if ! mount -o remount,ro,nochanges "$mnt" 2>/dev/null; then
          umount "$mnt"
          mount -t bcachefs -o ro,nochanges "$src" "$mnt"
        fi

        # Read all regular files
        err=0
        while IFS= read -r -d $'\0' f; do
          if ! dd if="$f" of=/dev/null bs=1M iflag=direct,nonblock status=none 2>/dev/null; then
            echo "READ-ERROR: $f" >&2
            err=1
          fi
        done < <(find "$mnt" -xdev -type f -print0)

        # Remount RW (best effort)
        if ! mount -o remount,rw "$mnt" 2>/dev/null; then
          umount "$mnt" || true
          mount "$mnt" || true
        fi

        # Collect kernel messages since start
        jlog="$logdir/verify-reads.''${esc}.log"
        {
          echo "===== $(date -Is) verify window: $start .. now ($mnt) ====="
          journalctl -k --since "$start" | grep -Ei 'bcachefs|I/O error|checksum|corrupt|bad block' || true
        } >> "$jlog"

        [[ "$err" -eq 0 ]] && echo "verify-reads: completed for $mnt; see $jlog" || \
          echo "verify-reads: completed with read errors for $mnt; see $jlog"
      done
    '';
  };

  # Schedule verify-reads to run at the NEXT 03:00.
  bcachefsVerifyReadsSchedule = mk {
    name = "bcachefs-verify-reads-schedule";
    runtimeInputs = with pkgs; [ systemd util-linux coreutils findutils ];
    text = ''
      if [[ $# -gt 0 ]]; then
        targets=("$@")
      elif [[ -n "''${BCACHEFS_TARGETS:-}" ]]; then
        read -r -a targets <<< "''${BCACHEFS_TARGETS}"
      else
        mapfile -t targets < <(findmnt -rn -t bcachefs -o TARGET | sort -u)
      fi

      if [[ ''${#targets[@]} -eq 0 ]]; then
        echo "bcachefs-verify-reads-schedule: no targets found"
        exit 0
      fi

      for mnt in "''${targets[@]}"; do
        esc="''${mnt//[^A-Za-z0-9_.-]/_}"
        unit="bcachefs-verify-reads-''${esc}"
        echo "Scheduling verify-reads for $mnt at next 03:00 as $unit"
        systemd-run --unit="$unit" \
          --on-calendar="03:00" \
          --timer-property=Persistent=true \
          "${bcachefsVerifyReads}/bin/bcachefs-verify-reads" "$mnt"
      done
    '';
  };

  # ---------- BCACHEFS: WRITEBACK POLICY ----------
  # Baseline throttle: 0 (keep HDDs idle). Raise during flush windows.
  bcachefsWritebackSet = mk {
    name = "bcachefs-writeback-set";
    runtimeInputs = with pkgs; [ coreutils findutils gawk gnused ];
    text = ''
      bytes="''${1:-''${BCACHEFS_MOVE_BYTES:-0}}"
      found=0
      for opt in /sys/fs/bcachefs/*/options/move_bytes_in_flight; do
        [[ -f "$opt" ]] || continue
        found=1
        echo "$bytes" > "$opt"
        echo "set $(basename "$(dirname "$(dirname "$opt")")") move_bytes_in_flight=$bytes"
      done
      [[ "$found" -eq 1 ]] || echo "No bcachefs options found under /sys/fs/bcachefs"
    '';
  };

  # Sum dirty/cached bytes: try internal/dirty_data, then writeback_dirty; else parse usage.
  bcachefsDirtyBytes = mk {
    name = "bcachefs-dirty-bytes";
    runtimeInputs = with pkgs; [ coreutils gawk gnugrep util-linux bcachefs-tools ];
    text = ''
      total=0
      # Preferred: internal/dirty_data (newer kernels/tools)
      for f in /sys/fs/bcachefs/*/internal/dirty_data; do
        [[ -f "$f" ]] || continue
        v="$(awk '{print $1}' "$f" 2>/dev/null || echo 0)"
        total=$(( total + v ))
      done

      # Fallback: writeback_dirty
      if [[ "$total" -eq 0 ]]; then
        for f in /sys/fs/bcachefs/*/writeback_dirty; do
          [[ -f "$f" ]] || continue
          v="$(awk '{print $1}' "$f" 2>/dev/null || echo 0)"
          total=$(( total + v ))
        done
      fi

      if [[ "$total" -gt 0 ]]; then
        echo "$total"
        exit 0
      fi

      # Last resort: parse "cached data" from `bcachefs fs usage --bytes`
      sum=0
      while read -r mnt; do
        out="$(bcachefs fs usage --bytes "$mnt" 2>/dev/null || true)"
        b="$(echo "$out" | grep -Eo 'cached data[^0-9]*([0-9]+)' | awk '{print $NF}' | head -n1)"
        [[ -n "$b" ]] || b=0
        sum=$(( sum + b ))
      done < <(findmnt -rn -t bcachefs -o TARGET | sort -u)
      echo "$sum"
    '';
  };

  # Threshold watcher: if dirty/cached >= LIMIT, open a flush window then restore to 0.
  bcachefsWritebackThresholdWatch = mk {
    name = "bcachefs-writeback-threshold-watch";
    runtimeInputs = with pkgs; [ coreutils gawk findutils util-linux bcachefs-tools ];
    text = ''
      LIMIT_BYTES="''${BCACHEFS_DIRTY_LIMIT:-161061273600}"   # 150 GiB
      FLUSH_BYTES="''${BCACHEFS_MOVE_BYTES_FLUSH:-268435456}" # 256 MiB inflight
      WINDOW_SEC="''${BCACHEFS_FLUSH_WINDOW_SECONDS:-7200}"   # 2 hours

      dirty="$("${bcachefsDirtyBytes}/bin/bcachefs-dirty-bytes")"
      if [[ "$dirty" -lt "$LIMIT_BYTES" ]]; then
        "${bcachefsWritebackSet}/bin/bcachefs-writeback-set" "0"
        echo "below threshold: ''${dirty} < ''${LIMIT_BYTES}"
        exit 0
      fi

      echo "threshold exceeded: ''${dirty} >= ''${LIMIT_BYTES}"
      "${bcachefsWritebackSet}/bin/bcachefs-writeback-set" "$FLUSH_BYTES"
      echo "Flush window open for ''${WINDOW_SEC}s..."
      sleep "$WINDOW_SEC"
      "${bcachefsWritebackSet}/bin/bcachefs-writeback-set" "0"
      echo "flush window closed."
    '';
  };

  # Daily scheduled flush window at 11:00 (local time).
  bcachefsWritebackScheduleDaily = mk {
    name = "bcachefs-writeback-schedule-daily";
    runtimeInputs = with pkgs; [ systemd coreutils ];
    text = ''
      FLUSH_BYTES="''${BCACHEFS_MOVE_BYTES_FLUSH:-268435456}"
      WINDOW_SEC="''${BCACHEFS_FLUSH_WINDOW_SECONDS:-7200}"
      unit="bcachefs-writeback-flush"

      cmd="${bcachefsWritebackSet}/bin/bcachefs-writeback-set"
      echo "Scheduling daily flush window at 11:00: +''${FLUSH_BYTES} for ''${WINDOW_SEC}s"
      systemd-run --unit="$unit" \
        --on-calendar="11:00" \
        --timer-property=Persistent=true \
        /bin/sh -c "$cmd $FLUSH_BYTES; sleep $WINDOW_SEC; $cmd 0"
    '';
  };

  # ---------- BOOT / FILESYSTEM HELPERS ----------
  mountESP = mk {
    name = "mount-esp-if-present";
    runtimeInputs = with pkgs; [ util-linux systemd coreutils gawk gnugrep ];
    text = ''
      CONFIRM="''${ENSURE_BOOT_CONFIRM:-1}"
      TIMEOUT="''${ENSURE_BOOT_TIMEOUT:-15}"
      ESP_GUID="c12a7328-f81f-11d2-ba4b-00a0c93ec93b"

      mountpoint -q /boot && exit 0
      udevadm settle || true
      DEV="$(lsblk -rno PATH,PARTTYPE,FSTYPE,PARTFLAGS \
        | awk -v g="$ESP_GUID" '($2==g || ($3=="vfat" && $4 ~ /esp/)) {print $1; exit}')"
      [[ -n "''${DEV:-}" ]] || exit 0

      if [[ "$CONFIRM" = "1" ]] && command -v systemd-ask-password >/dev/null 2>&1; then
        systemd-ask-password --timeout="$TIMEOUT" \
          "Mount ''${DEV} on /boot for this boot? (Y/n)" >/dev/null || exit 0
      fi

      mount -o ro "$DEV" /boot || exit 0
      mount -o remount,rw /boot || true
    '';
  };

  # Inventory the storage layout to state+manifests
  genStorageMap = mk {
    name = "gen-storage-map";
    runtimeInputs = with pkgs; [ util-linux coreutils gawk findutils gnugrep gnused jq python3 bcachefs-tools ];
    text = ''
      OUT_TXT="/srv/nixserver/state/storage-map.txt"
      OUT_JSON="/srv/nixserver/manifests/storage-map.json"
      TMP_TXT="''${OUT_TXT}.new"; TMP_JSON="''${OUT_JSON}.new"
      OLD_TXT="''${OUT_TXT}.old"; OLD_JSON="''${OUT_JSON}.old"

      {
        echo "# Dynamic Disk Map (auto-generated)"
        echo "# Device                                     Label         Size      FSType    UUID                                 PARTUUID"
        for dev in /dev/sd* /dev/nvme* /dev/vd* /dev/xvd* /dev/hd*; do
          [[ -b "$dev" ]] || continue
          label=$(lsblk -ndo LABEL "$dev" | head -n1)
          size=$(lsblk -ndo SIZE "$dev" | head -n1)
          fstype=$(lsblk -ndo FSTYPE "$dev" | head -n1)
          uuid=$(blkid -s UUID -o value "$dev" 2>/dev/null || echo "-")
          partuuid=$(blkid -s PARTUUID -o value "$dev" 2>/dev/null || echo "-")
          printf "%-45s %-13s %-9s %-8s %-36s %-36s\n" \
            "$dev" "${label:--}" "${size:--}" "${fstype:--}" "${uuid:--}" "${partuuid:--}"
          while read -r part; do
            label=$(lsblk -ndo LABEL "$part" | head -n1)
            size=$(lsblk -ndo SIZE "$part" | head -n1)
            fstype=$(lsblk -ndo FSTYPE "$part" | head -n1)
            uuid=$(blkid -s UUID -o value "$part" 2>/dev/null || echo "-")
            partuuid=$(blkid -s PARTUUID -o value "$part" 2>/dev/null || echo "-")
            printf "  %-43s %-13s %-9s %-8s %-36s %-36s\n" \
              "$part" "${label:--}" "${size:--}" "${fstype:--}" "${uuid:--}" "${partuuid:--}"
          done < <(lsblk -lnpo NAME "$dev" | tail -n +2)
        done

        echo
        echo "# Flat index (by label/UUID)"
        lsblk -Jpo NAME,LABEL,FSTYPE,UUID,PARTUUID,SIZE | jq -r '
          def row($p):
            @sh "  \($p.NAME)  label=\($p.LABEL // \"-\")  fstype=\($p.FSTYPE // \"-\")  uuid=\($p.UUID // \"-\")  partuuid=\($p.PARTUUID // \"-\")  size=\($p.SIZE // \"-\")";
          .blockdevices[] as $d
          | ([$d] + ($d.children // []))[]
          | row(.)
        '
      } > "$TMP_TXT"

      lsblk -Jpo NAME,TYPE,LABEL,FSTYPE,UUID,PARTUUID,SIZE,MOUNTPOINT > "$TMP_JSON"

      [[ -f "$OUT_TXT" ]] && mv -f "$OUT_TXT" "$OLD_TXT" || true
      [[ -f "$OUT_JSON" ]] && mv -f "$OUT_JSON" "$OLD_JSON" || true
      mv -f "$TMP_TXT" "$OUT_TXT"
      mv -f "$TMP_JSON" "$OUT_JSON"
      echo "Wrote $OUT_TXT and $OUT_JSON"
    '';
  };

  # ---------- MONITORING ----------
  monitoringMondaySmart = mk {
    name = "monitoring-monday-smart";
    runtimeInputs = with pkgs; [ util-linux hdparm smartmontools findutils gnugrep clamav coreutils ];
    text = ''
      LOGDIR="/srv/nixserver/state/monitoring/monday-10-30"
      mkdir -p "$LOGDIR"

      ALL_BLOCKS="$(lsblk -dn -o NAME | grep -E '^(sd|nvme|vd|xvd|hd)')"
      for d in $ALL_BLOCKS; do
        DEV="/dev/$d"; [[ -b "$DEV" ]] || continue
        hdparm -w "$DEV" || true
        sleep 3
        smartctl -t short "$DEV" || true
        echo "SMART short test triggered for $DEV at $(date)" >> "$LOGDIR/smart-monday.log"
        smartctl -a "$DEV" >> "$LOGDIR/smart-$d.log" || true
      done

      find / \
        \( -path /proc -o -path /sys -o -path /dev -o -path /run -o -path /nix/store \) -prune -o \
        -type f \( -iname '*.exe' -o -iname '*.dll' -o -iname '*.scr' -o -iname '*.bat' -o -iname '*.doc' -o -iname '*.docx' -o -iname '*.xls' -o -iname '*.xlsx' -o -iname '*.js' -o -iname '*.ps1' \) \
        -exec clamscan --infected --no-summary {} + 2>/dev/null \
      | tee -a "$LOGDIR/clamav-monday-infected.log"
    '';
  };

  monitoringPeriodic8h = mk {
    name = "monitoring-periodic-8h";
    runtimeInputs = with pkgs; [ hdparm clamav systemd smartmontools lm_sensors gnugrep nftables coreutils ];
    text = ''
      LOGDIR="/srv/nixserver/state/monitoring/periodic-8h"; mkdir -p "$LOGDIR"

      hdparm -w /dev/disk/by-label/detritus || true
      freshclam | tee -a "$LOGDIR/clamav-update.log" || true
      systemctl reload crowdsec || true
      echo "Crowdsec DB updated $(date)" >> "$LOGDIR/crowdsec-update.log"

      smartctl -a /dev/disk/by-label/detritus | tee -a "$LOGDIR/detritus-smart.log" || true

      echo "===== $(date '+%F %T') =====" >> "$LOGDIR/lmsensors.log"
      sensors >> "$LOGDIR/lmsensors.log" || true

      echo "===== $(date '+%F %T') =====" >> "$LOGDIR/journal-errors.log"
      journalctl --since "-8h" | grep -i error >> "$LOGDIR/journal-errors.log" || true

      echo "===== $(date '+%F %T') =====" >> "$LOGDIR/firewall.log"
      nft list ruleset >> "$LOGDIR/firewall.log" || true

      echo "===== $(date '+%F %T') =====" >> "$LOGDIR/logsizes.log"
      ls -lh "$LOGDIR" >> "$LOGDIR/logsizes.log" || true
    '';
  };

  monitoringFirewallCheck = mk {
    name = "monitoring-firewall-check";
    runtimeInputs = with pkgs; [ nftables coreutils systemd ];
    text = ''
      mkdir -p /srv/nixserver/state/monitoring/logs
      echo "===== $(date '+%F %T') =====" >> /srv/nixserver/state/monitoring/logs/firewall.check
      nft list ruleset >> /srv/nixserver/state/monitoring/logs/firewall.check || true
    '';
  };

  monitoringOnhoursCheck = mk {
    name = "monitoring-onhours-check";
    runtimeInputs = with pkgs; [ smartmontools bcachefs-tools e2fsprogs xfsprogs btrfs-progs coreutils util-linux findutils ];
    text = ''
      ROOTDEV="/dev/disk/by-label/weatherwax"
      BASEFILE="/srv/nixserver/state/monitoring/onhours-base.txt"
      STATEFILE="/srv/nixserver/state/monitoring/onhours-state.txt"
      LOGDIR="/srv/nixserver/state/monitoring/onhours-logs"; mkdir -p "$LOGDIR"

      if [[ ! -f "$BASEFILE" ]]; then
        HOURS="$(smartctl -A "$ROOTDEV" | awk "/Power_On_Hours/ {print \$10}")"
        echo "''${HOURS:-0}" > "$BASEFILE"
      fi

      BASE="$(cat "$BASEFILE")"
      CUR="$(smartctl -A "$ROOTDEV" | awk "/Power_On_Hours/ {print \$10}")"
      DELTA=$((CUR - BASE))
      {
        echo "On-hours since setup: $DELTA"
        date
      } > "$STATEFILE"

      # At 950h, schedule a verify-reads pass at next 03:00 (warn-only).
      if (( DELTA > 0 && DELTA % 950 == 0 )); then
        "${bcachefsVerifyReadsSchedule}/bin/bcachefs-verify-reads-schedule"
      fi

      # 2000h SMART long (local disks only)
      if (( DELTA > 0 && DELTA % 2000 == 0 )); then
        for d in /dev/sd? /dev/nvme?n?; do
          [[ -b "$d" ]] || continue
          smartctl -t long "$d" || true
        done
      fi
    '';
  };

  # ---------- SECRETS ----------
  # ensure-secrets: create encrypted placeholders for any mapped secret that doesn't exist yet.
  # Works with a private identity (/etc/agenix/key.txt) OR with only a public recipient (/etc/agenix/public.age).
  ensureSecrets = mk {
    name = "ensure-secrets";
    runtimeInputs = with pkgs; [ age openssl coreutils jq util-linux ];
    text = ''
      KEYDIR="/etc/agenix"
      PRIV="$KEYDIR/key.txt"
      PUB="$KEYDIR/public.age"
      MAP="/srv/nixserver/manifests/secrets-map.json"

      [[ -f "$MAP" ]] || { echo "ensure-secrets: $MAP missing"; exit 0; }

      RECIP=""
      if [[ -s "$PUB" ]]; then
        RECIP="$(awk 'NF{print $1; exit}' "$PUB")"
      elif [[ -s "$PRIV" ]]; then
        RECIP="$(age-keygen -y "$PRIV" | awk 'NR==1{print $1}')"
      else
        cat >&2 <<'EOM'
ensure-secrets: No age identity found.
- Provide /etc/agenix/key.txt (private) OR /etc/agenix/public.age (public).
- To generate:
    age-keygen -o /etc/agenix/key.txt
    age-keygen -y /etc/agenix/key.txt > /etc/agenix/public.age
EOM
        exit 2
      fi

      names=($(jq -r '.secrets|keys[]' "$MAP"))
      [[ ''${#names[@]} -gt 0 ]] || { echo "ensure-secrets: empty map"; exit 0; }

      umask 077
      for name in "''${names[@]}"; do
        file=$(jq -r --arg n "$name" '.secrets[$n].agePath' "$MAP")
        mode=$(jq -r --arg n "$name" '.secrets[$n].mode // "0400"' "$MAP")
        [[ -n "$file" && "$file" != "null" ]] || continue
        install -d -m 700 "$(dirname "$file")"
        if [[ ! -f "$file" ]]; then
          echo "Creating placeholder for $name at $file"
          printf '%s' "MISSING_SECRET" | age -a -r "$RECIP" -o "$file"
          chmod "$mode" "$file"
        fi
      done
    '';
  };

  # ---------- DISK TOOLING (TOML-driven → JSON manifest) ----------
  diskConfigTool = pkgs.writeShellApplication {
    name = "disk-config-tool";
    runtimeInputs = with pkgs; [ util-linux gawk gnused gnugrep coreutils findutils jq python3 bcachefs-tools ];
    text = ''
      OUT="/srv/nixserver/manifests/filesystems.json"
      TMP="$OUT.new"

      usage(){ echo "usage: $0 --apply /srv/nixserver/state/disk-plan.current.toml"; exit 2; }
      [[ $# -ge 2 && "$1" = "--apply" ]] || usage
      PLAN="$2"
      [[ -r "$PLAN" ]] || { echo "TOML plan not readable: $PLAN" >&2; exit 2; }

      python3 - "$PLAN" >"$TMP" <<'PY'
import sys, json, os
import tomllib  # Python 3.11+

plan_path = sys.argv[1]
with open(plan_path, "rb") as f:
    data = tomllib.load(f)

fs_list = data.get("filesystems") or []
if not isinstance(fs_list, list):
    print("error: [filesystems] must be an array of tables", file=sys.stderr)
    sys.exit(2)

out = []
for i, fs in enumerate(fs_list):
    mp = fs.get("mountPoint")
    dev = fs.get("device", "auto")
    fstype = fs.get("fsType", "auto")
    opts = fs.get("options", [])
    if not isinstance(opts, list):
        print(f"error: filesystems[{i}].options must be a list", file=sys.stderr)
        sys.exit(2)
    if not mp or not isinstance(mp, str):
        print(f"error: filesystems[{i}].mountPoint is required", file=sys.stderr)
        sys.exit(2)
    opts = [o for o in opts if isinstance(o, str) and o]
    entry = { "mountPoint": mp, "device": dev, "fsType": fstype }
    if opts:
        entry["options"] = opts
    out.append(entry)

print(json.dumps(out, indent=2))
PY

      install -D -m 0644 "$TMP" "$OUT"
      echo "Wrote $OUT"
    '';
  };

  # ---------- NIX STORE CLUMPED GC (wrapper → Python tool) ----------
  nixStoreClumpGc = pkgs.writeShellApplication {
    name = "nix-store-clumpgc";
    runtimeInputs = with pkgs; [ python3 nix coreutils ];
    text = ''
      set -euo pipefail
      exec /srv/nixserver/config/tools/nix-store-clumpgc.py \
        --policy /srv/nixserver/manifests/gc-policy.json \
        --map    /srv/nixserver/state/gc/index.json \
        --log    /srv/nixserver/state/gc/deleted.ndjson \
        --state-dir /srv/nixserver/state/gc \
        "$@"
    '';
  };

in
rec {
  inherit
    bcachefsVerifyReads
    bcachefsVerifyReadsSchedule
    bcachefsWritebackSet
    bcachefsDirtyBytes
    bcachefsWritebackThresholdWatch
    bcachefsWritebackScheduleDaily
    mountESP
    genStorageMap
    monitoringMondaySmart
    monitoringPeriodic8h
    monitoringFirewallCheck
    monitoringOnhoursCheck
    ensureSecrets
    diskConfigTool
    nix-store-clumpgc
    nixos-apply;

  paths = {
    "bcachefs-verify-reads"           = "${bcachefsVerifyReads}/bin/bcachefs-verify-reads";
    "bcachefs-verify-reads-schedule"  = "${bcachefsVerifyReadsSchedule}/bin/bcachefs-verify-reads-schedule";
    "bcachefs-writeback-set"          = "${bcachefsWritebackSet}/bin/bcachefs-writeback-set";
    "bcachefs-dirty-bytes"            = "${bcachefsDirtyBytes}/bin/bcachefs-dirty-bytes";
    "bcachefs-writeback-threshold"    = "${bcachefsWritebackThresholdWatch}/bin/bcachefs-writeback-threshold-watch";
    "bcachefs-writeback-schedule"     = "${bcachefsWritebackScheduleDaily}/bin/bcachefs-writeback-schedule-daily";
    "mount-esp-if-present"            = "${mountESP}/bin/mount-esp-if-present";
    "gen-storage-map"                 = "${genStorageMap}/bin/gen-storage-map";
    "monitoring-monday-smart"         = "${monitoringMondaySmart}/bin/monitoring-monday-smart";
    "monitoring-periodic-8h"          = "${monitoringPeriodic8h}/bin/monitoring-periodic-8h";
    "monitoring-firewall-check"       = "${monitoringFirewallCheck}/bin/monitoring-firewall-check";
    "monitoring-onhours-check"        = "${monitoringOnhoursCheck}/bin/monitoring-onhours-check";
    "ensure-secrets"                  = "${ensureSecrets}/bin/ensure-secrets";
    "disk-config-tool"                = "${diskConfigTool}/bin/disk-config-tool";
    "nix-store-clumpgc"               = "${nixStoreClumpGc}/bin/nix-store-clumpgc"; 
    "nixos-apply" 		      = "${nixosApply}/bin/nixos-apply";
  };
}
