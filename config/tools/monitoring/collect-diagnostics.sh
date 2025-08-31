#!/usr/bin/env bash
# ==============================================================================
# collect-diagnostics.sh  (v1)
# ------------------------------------------------------------------------------
# Purpose:
#   Capture a complete diagnostic snapshot after a suspected hang, black screen,
#   or network drop, so it can be scp'ed as ~/.logs to aid analysis.
#
# Usage:
#   collect-diagnostics.sh                  # write snapshot to ~/.logs
#   collect-diagnostics.sh --out /path.txt  # write to custom path
#   collect-diagnostics.sh --minimal        # skip heavy sections (dmidecode, lspci -k)
#
# Called by:
#   - monctl.sh (scheduled daily or via 'force diag-snapshot')
#   - Can be run manually by the operator
#
# Requirements:
#   - Utilities: journalctl, dmesg (run as root), lscpu, lspci, lsusb, free, dmidecode
#   - Optional: ip, ss, smartctl, sensors, nft, crowdsec, tailscale
#
# Output files:
#   - ~/.logs                # unified text snapshot (default)
#   - /srv/nixserver/backups/diag/<DATE>/...  # rotated copies for retention
#
# Notes:
#   - dmesg may be restricted if run without sudo (kernel.dmesg_restrict=1). We attempt
#     sudo and continue on failure.
#   - The script is safe to run repeatedly; it overwrites ~/.logs and rotates /srv copies.
# ==============================================================================

set -euo pipefail

# ---------- options ----------
OUT="${HOME}/.logs"
MINIMAL=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --out) OUT="$2"; shift 2 ;;
    --minimal) MINIMAL=1; shift ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

stamp="$(date -u +%Y-%m-%dT%H-%M-%SZ)"
rot_dir="/srv/nixserver/backups/diag/${stamp}"
mkdir -p "$(dirname "$OUT")" "$rot_dir" || true

# small helper to run and label sections
section() { printf "\n=== %s ===\n" "$1"; }
try() { "$@" 2>&1 || true; }

{
  section "Previous boot journal";         try journalctl -b -1 --no-pager -o short-monotonic
  section "Kernel errors (current)";       try sudo dmesg --level=err,crit,alert,emerg
  section "Hardware/MCE errors (previous boot)"; try journalctl -k -b -1 | egrep -i 'mce|hardware error|fatal'
  section "CPU info";                      try lscpu
  section "PCI devices";                   try lspci -nnk
  section "USB devices";                   try lsusb
  section "Memory info";                   try free -h
  section "Kernel cmdline";                try cat /proc/cmdline
  section "BIOS/DMI";                      if [[ "$MINIMAL" -eq 0 ]]; then try sudo dmidecode -t bios; else echo "skipped (--minimal)"; fi
  section "Block devices";                 try lsblk -e7 -o NAME,SIZE,MODEL,TYPE,MOUNTPOINT,UUID,FSTYPE
  section "Filesystems";                   try findmnt -t nofs -r -o TARGET,SOURCE,FSTYPE,OPTIONS
  section "SMART (summary)";               try (for d in /dev/sd? /dev/nvme?n?; do [[ -b "$d" ]] && sudo smartctl -H "$d"; done)
  section "Network (summary)";             try ip -br a; try ip r; try ss -tnp | head -200
  section "nftables snapshot";             try sudo nft list ruleset
  section "CrowdSec status";               try cscli -o text metrics | head -200
  section "Tailscale status";              try tailscale status
} > "$OUT"

# also copy to rotated directory
cp -f "$OUT" "${rot_dir}/logs.txt" 2>/dev/null || true

# keep a last-N retention under /srv/nixserver/backups/diag (default 14)
keep=14
cd /srv/nixserver/backups/diag 2>/dev/null || exit 0
ls -1dt */ 2>/dev/null | tail -n +$((keep+1)) | xargs -r -I{} rm -rf "{}"
