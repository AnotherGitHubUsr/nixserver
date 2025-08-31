# ==============================================================================
# flake.nix — entrypoint, channels, modules
# ------------------------------------------------------------------------------
# Assembles the system on nixos-25.05 with selective unstable (for crowdsec).
# Passes pkgs via readOnlyPkgs. Provides `secretsMap` and `manifestsPath`
# to modules; the latter is a store path to /srv/nixserver/manifests.
# ==============================================================================

{
  description = "NixOS headless server with agenix and CrowdSec (agent)";

  inputs = {
    # Pinned host manifests as a path input; becomes a store path when used
    manifests = { url = "path:/srv/nixserver/manifests"; flake = false; };

    # Channels
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable";

    # Tooling / modules
    agenix.url = "github:ryantm/agenix";
    flake-utils.url = "github:numtide/flake-utils";

    # CrowdSec module (engine + optional bouncer) maintained externally
    crowdsec-flake.url = "git+https://codeberg.org/kampka/nix-flake-crowdsec";
  };

  outputs = { self, nixpkgs, nixpkgs-unstable, agenix, crowdsec-flake, manifests, ... }:
  let
    system = "x86_64-linux";

    # Stable pkgs; pull crowdsec from unstable
    pkgs = import nixpkgs {
      inherit system;
      overlays = [
        (final: prev: {
          crowdsec = nixpkgs-unstable.legacyPackages.${system}.crowdsec;
        })
      ];
    };

    pkgsUnstable = nixpkgs-unstable.legacyPackages.${system};

    # Helpers to read JSON from a store path
    readJson = path:
      if builtins.pathExists path then builtins.fromJSON (builtins.readFile path) else null;

    filesystemsPath = builtins.toPath "${manifests}/filesystems.json";
    secretsMapPath  = builtins.toPath "${manifests}/secrets-map.json";

    fsList     = let v = readJson filesystemsPath; in if v == null then [ ] else v;
    secretsMap = let v = readJson secretsMapPath;  in if v == null then { version = 1; secrets = {}; } else v;
  in
  {
    nixosConfigurations = {
      nixserver = nixpkgs.lib.nixosSystem {
        specialArgs = {
          pkgs = pkgs;
          pkgsUnstable = pkgsUnstable;
          agenix = agenix;

          # Provide both parsed data and the manifests store path
          manifestsPath = manifests;        # store path to /srv/nixserver/manifests
          inherit fsList secretsMap;        # parsed JSON payloads
        };

        modules = [
          { nix.settings.experimental-features = [ "nix-command" "flakes" ]; }
          nixpkgs.nixosModules.readOnlyPkgs
          ({ pkgs, ... }: {
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
