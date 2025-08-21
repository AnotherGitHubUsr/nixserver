# =========================
# users.nix
# =========================
# --- USER ACCOUNTS, SUDO, SHELL, AUTH KEYS, PASSWORDS ---
# User and SSH setup. Password from agenix, fallback pubkey.
# Locale set to English (UK); console keyboard layout set to German (QWERTZ).
# ---------------------------------------------------------

{ config, pkgs, agenix, ... }:

let
  # --- GET HASHED PASSWORD FROM AGENIX ---
  nixuserPasswordFile = "/run/agenix/nixuser-password.hash";

/*  # --- GITHUB SSH KEYS WITH FALLBACK ---
  githubKeyUrl = "https://github.com/AnotherGitHubUsr.keys";
  localFallbackKeys = builtins.readFile ./secrets/nixuser.authorized_keys.fallback;
  fetchGithubKeys = builtins.tryEval (builtins.fetchurl { url = githubKeyUrl; sha256 = null; });
  authorizedKeys = if fetchGithubKeys.success then builtins.readFile fetchGithubKeys.value else localFallbackKeys;
*/
in
{
  # --- LOCALE & KEYBOARD (HEADLESS-FRIENDLY) ---
  # System language: English (UK). Console keymap: German (standard QWERTZ).
  i18n.defaultLocale = "en_GB.UTF-8";
  i18n.supportedLocales = [
    "en_GB.UTF-8/UTF-8"
    "de_DE.UTF-8/UTF-8"
  ];
  console.keyMap = "de";

  # --- MAIN USER ---
  users.users.nixuser = {
    isNormalUser = true;
    description = "main server user";
    home = "/home/nixuser";
    extraGroups = [ "wheel" "docker" "incus" ];
    shell = pkgs.nushell;
    hashedPasswordFile = nixuserPasswordFile;
    # moved to security.nix. remove there for better security. #sudo = { extraRules = [ { users = [ "nixuser" ]; commands = [ "ALL" ]; nopasswd = true; } ]; };
    # openssh.authorizedKeys.keys = builtins.split "\n" authorizedKeys;
  };
  # If nushell causes trouble, switch to bash by uncommenting:
  # users.users.nixuser.shell = pkgs.bash;

  # --- DISABLE ROOT LOGIN ---
  users.users.root.hashedPassword = "*";
}
