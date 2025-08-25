# =========================
# flake.nix
# =========================
# --- FLAKE ENTRYPOINT, CHANNEL PINS, MODULE LIST ---
# Disko has been commented out as requested; keep for future use.
# --------------------------------------------------

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
