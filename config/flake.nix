# ==============================================================================
# flake.nix — Entrypoint, channel pins, module graph
# ------------------------------------------------------------------------------
# Purpose:
#   Compose the system from nixpkgs 25.05 (stable), selectively pull packages from
#   nixpkgs-unstable, and pass pinned manifests to modules via specialArgs.
#
# Policy:
#   - Modules must use `pkgs` from specialArgs (readOnlyPkgs enforced).
#   - No eval-time reads from /etc; host data comes from pinned `manifests`.
#
# Usage:
#   # Build, activate, mirror, export, and autocommit via repo tool:
#   nixos-apply --host nixserver [--show-trace] [--no-mirror] [--no-export] [--no-git]
#   # optional: override flake path
#   nixos-apply --flake /srv/nixserver/config --host nixserver
#
# Flake/lock management:
#   # Update every input to latest allowed by URLs in this flake:
#   nix flake update
#   # Update a single input:
#   nix flake lock --update-input nixpkgs
#   nix flake lock --update-input nixpkgs-unstable
#   # Pin an input to a specific revision or tag:
#   nix flake lock --override-input nixpkgs github:NixOS/nixpkgs/<rev-or-tag>
#   # Inspect current lock state:
#   nix flake metadata
#
# Compatibility:
#   NixOS 25.05, Linux 6.15+. ZFS ≥ 2.3.3 via `boot.zfs.package` (stable-first, fallback to unstable).
# ==============================================================================


{
  description = "Flake for NixOS headless server (with agenix, stable/unstable pkgs, crowdsec module)";

  inputs = {
    # Host-local manifests pinned as a non-flake path (copied to the store and locked)
    manifests = { url = "path:/srv/nixserver/manifests"; flake = false; };

    # Channels
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable";

    # Tools / modules
    agenix.url = "github:ryantm/agenix";
    flake-utils.url = "github:numtide/flake-utils";

    # CrowdSec community module (restores services.crowdsec on 25.05+)
    crowdsec-flake.url = "git+https://codeberg.org/kampka/nix-flake-crowdsec";
  };

  outputs = { self, nixpkgs, nixpkgs-unstable, agenix, crowdsec-flake, manifests, ... }:
  let
    system = "x86_64-linux";

    # Primary pkgs set (stable), with a small overlay pulling only 'crowdsec' from unstable.
    pkgs = import nixpkgs {
      inherit system;
      overlays = [
        (final: prev: {
          crowdsec = nixpkgs-unstable.legacyPackages.${system}.crowdsec;
        })
      ];
    };

    # Convenience handle to the full unstable set (optional)
    pkgsUnstable = nixpkgs-unstable.legacyPackages.${system};

    # ---- Read manifest data from the store-locked path input ----
    # Helper to read JSON if present
    readJson = path:
      if builtins.pathExists path
      then builtins.fromJSON (builtins.readFile path)
      else null;

    filesystemsPath = builtins.toPath "${manifests}/filesystems.json";
    secretsMapPath  = builtins.toPath "${manifests}/secrets-map.json";

    fsList =
      let v = readJson filesystemsPath;
      in if v == null then [ ] else v;

    # Expect shape: { version = 1; secrets = { <name> = { agePath=...; ... }; }; }
    secretsMap =
      let v = readJson secretsMapPath;
      in if v == null then { version = 1; secrets = {}; } else v;

  in {
    nixosConfigurations = {
      nixserver = nixpkgs.lib.nixosSystem {
        # system = "x86_64-linux";   # ← remove this
        specialArgs = {
          pkgs = import nixpkgs {
            system = "x86_64-linux";
            overlays = [
              (final: prev: {
                crowdsec = (import nixpkgs-unstable { system = "x86_64-linux"; }).crowdsec;
              })
            ];
          };
          pkgsUnstable = import nixpkgs-unstable { system = "x86_64-linux"; };
          agenix = agenix;

          # Pass both the store path and parsed data to modules
          manifestsPath = manifests;        # store path to /manifests
          inherit fsList secretsMap;        # parsed JSON data
        };

        modules = [
          { nix.settings.experimental-features = [ "nix-command" "flakes" ]; }
          nixpkgs.nixosModules.readOnlyPkgs
          ({ pkgs, ... }: {
            # use the pkgs from specialArgs for all modules
            nixpkgs.pkgs = pkgs;
            system.stateVersion = "25.05";
          })
          ./configuration.nix
          agenix.nixosModules.default
          crowdsec-flake.nixosModules.crowdsec
        ];
      };
    };
  };
}