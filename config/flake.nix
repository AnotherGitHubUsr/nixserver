# =========================
# flake.nix
# =========================
# --- FLAKE ENTRYPOINT, CHANNEL PINS, MODULE LIST ---
# Disko has been commented out as requested; keep for future use.
# --------------------------------------------------

{
  description = "Flake for NixOS headless server (with agenix, stable/unstable pkgs, crowdsec module)";

  # --- Flake Inputs: Define all source channels and tools
  inputs = {
    manifests.url = "path:/srv/nixserver/manifests";
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";                 # Stable channel for system/core packages
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable";     # Unstable channel for opt-in bleeding edge pkgs (follows 25.05-unstable branch)
/*  disko.url = "github:nix-community/disko";                         # Declarative partitioning (Disko module) — DISABLED */
    agenix.url = "github:ryantm/agenix";                              # Encrypted secrets management (agenix)
    flake-utils.url = "github:numtide/flake-utils";                   # Utility helpers for multi-system output

    # --- CROWDSEC COMMUNITY MODULE ---
    # Provides a maintained replacement for 'services.crowdsec' after its removal from NixOS 25.05+.
    crowdsec-flake.url = "git+https://codeberg.org/kampka/nix-flake-crowdsec";
  };

  # --- Outputs: Build the configuration set
  outputs = { self, nixpkgs, nixpkgs-unstable, /*disko,*/ agenix, crowdsec-flake, ... }: {
    nixosConfigurations = {
      nixserver = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";

        # --- Special arguments for package/channel selection ---
        specialArgs = {
          pkgs = import nixpkgs {
            system = "x86_64-linux";
            overlays = [
              # --- CROWDSEC PACKAGE FROM UNSTABLE ---
              # Ensures any usage of pkgs.crowdsec (CLI, module) is always the latest from unstable.
              (final: prev: {
                crowdsec = import nixpkgs-unstable { system = "x86_64-linux"; }.crowdsec;
              })
            ];
          };
          pkgsUnstable = import nixpkgs-unstable { system = "x86_64-linux"; };
          agenix = agenix;
        };

        \1 ({ config, ... }: { nix.settings.experimental-features = [ "nix-command" "flakes" ]; }) # --- Enforces use of the given pkgs for all NixOS modules. Disables ignored overlays/config for reproducibility and compatibility with specialArgs.pkgs ---
          ({ config, ... }: {
            nixpkgs.pkgs = import nixpkgs {
              system = "x86_64-linux";
              overlays = [
                (final: prev: {
                  crowdsec = import nixpkgs-unstable { system = "x86_64-linux"; }.crowdsec;
                })
              ];
            };
            # --- NIXOS VERSION LOCK ---
            system.stateVersion = "25.05"; # Lock system state version to 25.05 for stable, reproducible upgrades.
          })

          ./configuration.nix          # Main config imports (all modular .nix)
/*        disko.nixosModules.disko     # Disko module (partition layout) — DISABLED */
          agenix.nixosModules.default  # Age/agenix secrets module

          # --- CROWDSEC NIXOS MODULE FROM COMMUNITY FLAKE ---
          # Restores 'services.crowdsec' and all module options in a fully maintained way.
          crowdsec-flake.nixosModules.crowdsec
        ];
      };
    };
  };
}
