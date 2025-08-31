# nixserver
> Flake-based NixOS headless server configuration with reproducible state, secrets, monitoring, and GitOps.
> Version 2.0 might be called "Nearly Headless NickServer" 

## Quick start
```bash
# 0) Install NixOS 25.05 from the ISO (minimal/server).
# 1) Prepare the host directory and clone this repository.
sudo mkdir -p /srv/nixserver
cd /srv/nixserver
sudo git clone https://github.com/AnotherGitHubUsr/nixserver config

# 2) (Optional) Recommended: set your own Git remote BEFORE any auto-push.
#    Choose SSH or HTTPS as you prefer:
git -C /srv/nixserver/config remote set-url origin git@github.com:<you>/<your-repo>.git
# or
git -C /srv/nixserver/config remote set-url origin https://github.com/<you>/<your-repo>.git

# 3) FIRST RUN: tools are not on PATH yet → call them by full path.
sudo /srv/nixserver/config/tools/disk-config-tool.sh --generate
sudo /srv/nixserver/config/tools/secretsctl add --ask --confirm initial_secret

# 4) Build, switch, mirror, export, and push (first run uses full path).
sudo /srv/nixserver/config/tools/nixos-apply.sh --host nixserver
```
> After the first successful switch, the NixOS module places these tools on `PATH`.
> From then on, use short names (`nixos-apply.sh`, `secretsctl`, `disk-config-tool.sh`, `monctl.sh`, etc.) without full paths.

## Requirements
- NixOS 25.05, Nix ≥ 2.18.
- Provided by the flake: `age`, `agenix`, `jq`, `python3`, `util-linux`, `git`, `rsync`, `shellcheck`, `shfmt`, `smartctl`, `nftables`, `clamav`, `lm_sensors`.

## Host paths & files
```
/srv/nixserver/
├─ config/                         # Git working copy of this repo (flake, modules, tools)
│  ├─ flake.nix                    # Flake entrypoint: inputs, overlays, outputs, hosts
│  ├─ *.nix                        # Module set for this host (edit to change behaviour)
│  │  ├─ disk.nix                  # Reads manifests/filesystems.json → defines mounts
│  │  ├─ users.nix                 # User accounts, SSH, sudo
│  │  ├─ pkgs.nix                  # System packages and overlays (stable + unstable)
│  │  ├─ kernel.nix                # Kernel pin and tuning
│  │  ├─ monitoring.nix            # Timers/services for monitoring jobs
│  │  ├─ network.nix               # Interfaces, VLANs, firewall base
│  │  ├─ secrets.nix               # Agenix wiring: age recipients, secret paths
│  │  └─ security.nix              # Security hardening toggles
│  └─ tools/                       # Helper CLIs; installed onto PATH after first switch
│     ├─ nixos-apply.sh            # Build → switch → mirror /etc/nixos → export → git push
│     ├─ disk-config-tool.sh       # Live inventory → TOML plan → manifests/filesystems.json
│     ├─ secretsctl                # Manage age/agenix secrets; rotate; check; gen-ssh
│     ├─ export-release.sh         # Snapshot active system → /srv/nixserver/releases/<ID>
│     ├─ git-autocommit-push.sh    # Commit → pull --rebase → push (deploy key/fork)
│     ├─ lint-scripts.sh           # shellcheck + shfmt
│     ├─ monctl.sh                 # Timer-friendly scheduler for monitoring tasks
│     └─ monitoring/               # Periodic jobs called by monctl.sh
│        ├─ bcachefs-verify-reads.sh              # Read-only scrub across files
│        ├─ bcachefs-writeback-threshold-watch.sh # Open flush window on dirty threshold
│        ├─ bcachefs-writeback-flush-window.sh    # Manual flush window helper
│        ├─ monitoring-periodic-8h.sh             # freshclam, crowdsec reload, sensors, logs
│        ├─ monitoring-monday-smart.sh            # Weekly SMART + quick ClamAV sweep
│        ├─ monitoring-firewall-check.sh          # nft ruleset snapshot
│        └─ monitoring-onhours-check.sh           # Activity gated by SMART on-hours
├─ manifests/                     # Machine-consumed JSON generated from human TOML
│  └─ filesystems.json            # Written by disk-config-tool.sh --apply
├─ state/                         # Human-maintained or long-lived state
│  ├─ disk-plan.current.toml      # **Human-editable** filesystem plan (edit this)
│  ├─ secrets-map.json            # age/agenix secret map maintained by secretsctl
│  └─ …                           # keys, counters, release metadata
├─ backups/                       # Mirrors of /etc/nixos and logs
└─ incoming/                      # Scratch dropzone for scp/rsync before triage
```

## Usage
### System rebuilds
- First run: `sudo /srv/nixserver/config/tools/nixos-apply.sh --host nixserver`
- Later: `sudo nixos-apply.sh`

### Filesystems
- `sudo disk-config-tool.sh --generate`   — create/update plan TOML from live mounts
- **Edit `/srv/nixserver/state/disk-plan.current.toml` to make human-readable changes**
- `sudo disk-config-tool.sh --apply`      — write `manifests/filesystems.json` for NixOS
- `sudo disk-config-tool.sh storage-map --txt --json`

### Secrets (agenix/age)
- First run: `sudo /srv/nixserver/config/tools/secretsctl add --ask --confirm name`
- Later: `sudo secretsctl add|list|check|rotate`
- Generate SSH key as a secret: `sudo secretsctl gen-ssh --name deploy_ssh --comment "nixserver"`
- Verify decryptability: `sudo secretsctl check --any`

### Monitoring
- `monctl.sh run` via systemd timer after first switch.

## Workflows
- Update flake inputs and switch:
  ```bash
  nix flake update
  sudo nixos-apply.sh
  ```
- Releases: `/srv/nixserver/releases/<ID>/` with `release.json` and GC root.
- `/etc/nixos` mirror: automatic after successful switch to `/srv/nixserver/backups/etc-nixos/<timestamp>/`.

## Troubleshooting
- Git remote:
  - This template initially points to its (THIS) origin. Pushing to that repo will fail. **Copy-left to your own repo** and set the remote:
    ```bash
    git -C /srv/nixserver/config remote set-url origin git@github.com:<you>/<your-repo>.git
    ```
- Autocommit “unstaged changes”: helper stages via `git add -A` before rebase; re-run `nixos-apply.sh`.
- Disk plan TOML errors: ensure unique tables and arrays; use `/dev/disk/by-uuid` for `/boot`, labels elsewhere.
- Secrets check fails: ensure `/etc/agenix/key.txt` exists or pass `--identity` to `secretsctl check`.

## Security
- Secrets encrypted with `age`; plaintext kept only in `/dev/shm` during operations.
- Break-glass public keys verified before rotation; recipients file managed by `agenix`.
- Regular updates via `nixos-apply.sh`; review release metadata for `rebootRequired`.

## "Contributing"
- **Feel free to copy-left this repo to your own repository** for any changes or extensions you want to maintain.
- Run `tools/lint-scripts.sh` and `nix flake check` before commits.
- Keep configuration paths obvious and heavily commented.

## License
This project is licensed under the GNU General Public License v3.0 (GPL-3.0). See `LICENSE` for the full text.

This program is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3 or any later version.

This program is distributed in the hope that it will be useful, but **without any warranty**; without even the implied warranty of **merchantability** or **fitness for a particular purpose**. See the GNU General Public License for more details. (https://www.gnu.org/licenses/gpl-3.0.txt)

Non-legal personal comments:
<sub> Anyone, whether I would like you or your usecase, should be able to use and adapt the software in this repo. Just make sure to copy-left, eh? </sub>
Parts of this, especially the comments, are created by AI. I'm pretty sure I haven't used anything without checking, changing and updating though. Nevertheless:
**Any commercial use is strongly discouraged**
