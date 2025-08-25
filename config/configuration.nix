# =========================
# configuration.nix
# =========================
# --- SYSTEM CONFIGURATION ENTRYPOINT ---
# Imports all modular .nix configs. For module description see index.txt.
# Also adds iSCSI support and adds tools from scripts.nix to the PATH
# ---------------------------------------

{ config, pkgs, pkgsUnstable, agenix, ... }:

let
  scripts = import ./scripts.nix { inherit pkgs; };
in
{
  # --- MODULE IMPORTS ---
  imports = [
    ./users.nix
    ./disk.nix
    ./pkgs.nix
    ./network.nix
    ./security.nix
    ./monitoring.nix
    ./secrets.nix
    ./kernel.nix
  ];

  nix.settings.experimental-features = [ "nix-command" "flakes" ];


  # --- Adds Tools from scripts.nix on PATH
  environment.systemPackages = [
    scripts.nixosApply
      # e.g. scripts.diskConfigTool scripts.ensureSecrets …
    ];

  # --- ISCSI CLIENT SERVICE ---
  # Enables open-iscsi system integration. All options go in extraConfig; secrets are loaded from agenix.
  services.openiscsi = {
    enable = true;
    name = "iqn.2025-08.nixserver"; #this is absolutely required. Don't remove it!
    extraConfig = ''
      node.startup = automatic
      discovery.sendtargets.address = 10.250.250.249
      discovery.sendtargets.port = 3260
    '';
  };

}
