---

# Headless Nixserver

All of this is very much personal. It is tailored to my setup and what I want (not necessarily what I need).  
<p align="center"><b>YMMV</b></p>
Version 2.0 might be called Almost Headless NickServer

copyleft!

---

# nixserver

Headless NixOS host configuration for a home-lab server, built with flakes and designed for reproducible operations, safe storage workflows, and Git-based change control.

- Target OS: NixOS 25.05  
- Kernel baseline: 6.15  
- Filesystems: OpenZFS compatible with 2.3.3, bcachefs tools installed  
- Secrets: Age/Agenix  
- Networking: ready for Tailscale and typical home-lab services

---

## Overview

This repository is the _source of truth_ for a single host called `nixserver`. You keep it under Git, generate machine-consumable **manifests** from interactive tools, and deploy via `nixos-rebuild` or helper wrappers. The working copy typically lives at `/srv/nixserver/config` on the host.

### Design goals

- Deterministic builds with flakes.  
- Human-editable plans → generated manifests → declarative modules.  
- Secrets live outside the Nix store encrypted with Age, mapped by an explicit manifest.  
- Safe GitOps: commit locally, rebase on pull, push once reconciled.  
- Extensive comments and clearly marked extension points.

---

## Layout

```
/srv/nixserver/                  # Root of the working copy and host state
├─ config/                       # Git-tracked configuration
│  ├─ flake.nix                 # Flake entrypoint and channel pins
│  ├─ flake.lock                # Pin for reproducible builds
│  ├─ configuration.nix         # Top-level imports and host profile
│  ├─ kernel.nix                # Kernel, initrd, microcode, ZFS enable
│  ├─ network.nix               # Interfaces and optional Tailscale
│  ├─ security.nix              # SSH, firewall, optional CrowdSec
│  ├─ secrets.nix               # Agenix integration and secret wiring
│  ├─ monitoring.nix            # SMART, timers, health checks
│  ├─ pkgs.nix                  # Package sets and overlays
│  ├─ scripts.nix               # Helper binaries via writeShellApplication
│  ├─ users.nix                 # Users and groups
│  └─ tools/                    # Operational scripts
│     ├─ disk-config-tool.sh    # Edit/validate/export disk plan → manifests/filesystems.json
│     ├─ export-release.sh      # Stamp a release ID and export metadata
│     ├─ git-autocommit-push.sh # Stage/commit; pull --rebase --autostash; push if ahead
│     ├─ health-report.sh       # Capture system health and SMART snapshots
│     ├─ lint-scripts.sh        # Run shell/py linters and formatting checks
│     ├─ nix-store-clumpgc.py   # Opportunistic nix-store GC helper
│     ├─ nixos-apply.sh         # Build-and-switch wrapper with extra args passthrough
│     ├─ secretsctl             # Age/Agenix helper: add/rotate/verify/gen-ssh
│     └─ switch-to.sh           # Focused profile switch with clear exit codes
│
├─ manifests/                    # Generated inputs (do not hand-edit)
│  ├─ filesystems.json           # Mount plan exported by disk tool
│  └─ secrets-map.json           # Secret map: recipients and storage paths
│
├─ state/                        # Long-lived state, plans, keys, exported artifacts
├─ backups/                      # Dated archives and logs
└─ incoming/                     # Scratch dropzone for scp/rsync before triage
```

These paths are referenced by scripts and are expected to exist on the machine.

---

## Build and deploy

Helper wrappers in `config/tools/`:

- **`nixos-apply.sh`**  
  Build, show a short log, switch and push to github. Accepts `--host` and `--extra` args to pass through to `nixos-rebuild`.

- **`switch-to.sh`**  
  Focused switch wrapper with clearer exit codes. Good for timers.

- **`git-autocommit-push.sh`**  
  Stages and commits local changes, then `git pull --rebase --autostash`, then pushes if ahead. Designed for deploy keys.

---

## Storage

**ZFS** and **bcachefs** are enabled. The system keeps both ready so you can choose per dataset. Bcachefs is commented until needed (expected to be dropped from future Kernels).

---

### Disk planning and manifests

Original Plan was to use **disko**, but the chance of disko accidentally formatting a disk with Disko was... unfavourable. Therefore custom scripts are being used:

- **Plan** with `disk-config-tool.sh`  
  - Writes a human-facing TOML plan into `/srv/nixserver/state/…`  
  - Exports human-made changes to the TOML plan to a machine-readable JSON mount map into `manifests/filesystems.json`

- **Consume** in `disk.nix`  
  - Reads `filesystems.json` and emits `fileSystems` entries  
  - Respects `KEEP` flags so you can mount existing data without formatting

Typical workflow:

```bash
# Start or edit the plan
sudo disk-config-tool.sh --plan

# Preview and validate
sudo disk-config-tool.sh --preview

# Export to manifests
sudo disk-config-tool.sh --export

# Deploy the mounts
sudo nixos-apply.sh
```

Safety notes:

- Plans explicitly declare `device`, `fsType`, `label`, `mountPoint`, and whether to format or keep.  
- The tool refuses destructive actions unless flags are set.  
- `manifests/` is generated. Do not hand-edit.

---

## Secrets

Agenix and Age provide encryption at rest and clean store semantics.

- **`manifests/secrets-map.json`**  
  Maps logical secret names to recipients and storage paths. It is generated or maintained alongside the Age key lifecycle.

- **`secrets.nix`**  
  Declares how secrets are exposed to services or paths at activation time.

- **Tooling: `secretsctl`**  
  High-level operations:
  - `secretsctl add --stdin <name>`  
    Read secret from stdin and encrypt per `secrets-map.json`.
  - `secretsctl add --from-file <path> <name>`  
    Ingest a file as a secret.
  - `secretsctl gen-ssh --name <name> [--pub-out <path>]`  
    Generate an SSH keypair. Private key is encrypted to Age. Public key is written for external use.
  - `secretsctl rotate --name <name>`  
    Re-encrypt for new recipients, e.g. after key rotation.
  - `secretsctl verify`  
    Check that break-glass and standard identities can decrypt as expected.

Operational guidance:

- Keep Age identities in `/srv/nixserver/state/keys/`.  
- Store break-glass identities offline and verify periodically.  
- Never commit decrypted material. The repo should never contain even `.age` files, keep it that way! Only the `secrets-map.json` should be in the repo/nixstore.

---

## GitOps

Use the repo like a traditional Git project but prefer fast-forwarded history.

- Local commit and reconcile:
  ```bash
  git-autocommit-push.sh
  ```
  Behaviour:
  - `git add -A`  
  - Commit only if staged changes exist  
  - `git pull --rebase --autostash`  
  - Push only if ahead of upstream

- Deploy keys can be generated by secretsctl and should be managed with agenix.

- Common recovery:
  - If rebase stops on conflict, resolve and `git rebase --continue`.  
  - If upstream is missing, the script initialises tracking on first push.

---

## Monitoring and health

- **`health-report.sh`**  
  Collect system metrics and SMART summaries into `/srv/nixserver/backups/health/<date>/`.

- SMART and periodic checks are defined in `monitoring.nix`.  
- Add your own timers by copying the commented examples.

---

## Networking

- `network.nix` includes standard interface definitions and port management.
- To enable Tailscale, supply your "tailscale-authkey" with secretsctl.

---

## Packages and overlays

- Stable base: `nixos-25.05`.  
- Optional `nixos-unstable` overlay is pre-wired for selective packages.  
- All modules use a **single** `pkgs` passed via `specialArgs`. (hopefully)  
- `nixpkgs.nixosModules.readOnlyPkgs` is included to prevent accidental in-module `pkgs` re-imports.  
- Extend by editing `pkgs.nix` and the overlay stub.

---

## Extending the system

Common extension points are (meant to be) commented and ready to un-comment:

- Extra services in `configuration.nix`  
- Additional mounts in the disk plan (then export to manifest)  
- Extra packages in `pkgs.nix`  
- Additional health checks in `monitoring.nix`

Each file ought to start with a header-like comment and should be commented throughout with one-line descriptive/rational comments. - If not... I intend to fix that soon (TM).

---

## Operational cheat-sheet

```bash
# Build and switch the host
sudo nixos-apply.sh

# Stage, rebase and push changes
git-autocommit-push.sh

# Plan and export storage
disk-config-tool.sh --plan
disk-config-tool.sh --apply

# Add a secret from stdin
echo -n "value" | secretsctl add --stdin app/db-password

# Add a secret with a masked tty
secretsctl add supersecret

# Generate an SSH key as a secret and write the public key
secretsctl gen-ssh --name foo/bar --pub-out /srv/nixserver/state/keys/deploy.pub

# Quick health snapshot
health-report.sh
```

---

## Conventions and guarantees

- `manifests/` is generated. Do not edit by hand.  
- `state/` contains machine-local information. Generally more human-facing.
- `incoming/` is a convenience dropzone. Move its contents into `state/` or a proper manifest as soon as practical.  
- ZFS is enabled via `boot.supportedFilesystems`. No manual kernel module pinning.  
- bcachefs uses only userspace tools on 6.15. A commented fallback exists if you adopt a kernel without in-tree support.

---

## Troubleshooting

- **Build errors about unknown options**  
  Confirm the repo’s pinned NixOS channel matches 25.05.

- **ZFS refuses to import a pool**  
  Check kernel and userspace match the channel. Do not mix arbitrary ZFS packages.

- **`git pull` complains about unstaged changes**  
  Run `git status`, then use the provided git scripts which autostashes on rebase.

- **Secrets not visible at runtime**  
  Ensure `secrets-map.json` includes the secret and that `secrets.nix` wires it to the consumer path.

---

## Roadmap

- Optional out-of-tree bcachefs module hook if kernel drops in-tree.  
- Potentially a similar approach to networking as to mounting.
- Actually useful things either as docker containers or apps.
- Proper usage of Crowdsec and ClamAV.
- More health checks and power-saving timers for headless use.

---

## Contact:
  I'm not sure why anyone might want to contact me, as I can very clearly NOT give any sort of support or similar.
  If this doesn't disinsentivice you, feel free to contact me at:
	github.skeptic613@passinbox.com

(this is a forwarded E-Mail. If I end up getting tons of spam I'll just disable it. Sorry)

---

## License

    This Repository is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    any later version.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.
	https://www.gnu.org/licenses/gpl-3.0.txt

(non-legal personal opinion: whether I might personally like you or not, you should be allowed to use this. If you were to use/adapt/... for redistribution, just use GPL-3 and try to make sure it's useful, eh?)
    



_End of README_
