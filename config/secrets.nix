# ------------------------------------------------------------------------------
# secrets.nix — Map-driven Agenix integration for NixOS
#
# Contract / layout
#   • Encrypted blobs live outside the repo at:  /var/lib/agenix/<name>.age
#   • Host-local map (JSON) lives at:            /srv/nixserver/manifests/secrets-map.json
#   • Dedicated Age identity on host:            /etc/agenix/key.txt  (0600)
#     Public recipients (one per line):          /etc/agenix/public.age  (0644)
#
# How it works
#   • The *flake* reads secrets-map.json and passes it here as `secretsMap`.
#   • Valid entries (name → { agePath, mode?, owner?, group? }) are turned into
#     agenix secrets. At ACTIVATE, Agenix decrypts to /run/agenix/<name>.
#
# Notes / best practices
#   • Do NOT read decrypted secrets with builtins.readFile (would leak to store).
#   • Services should consume files via:  config.age.secrets.<name>.path
#   • Create/rename/remove secrets with the companion CLI: `secretsctl`.
# ------------------------------------------------------------------------------

{ config, lib, pkgs, secretsMap ? { version = 1; secrets = {}; }, ... }:

let
  # Use the versioned schema; anything else becomes empty
  rawMap =
    if (builtins.isAttrs secretsMap) && (secretsMap ? secrets) && (builtins.isAttrs secretsMap.secrets)
    then secretsMap.secrets
    else {};

  validEntry = v:
    (builtins.isAttrs v)
    && (v ? agePath)
    && (builtins.isString v.agePath)
    && lib.hasPrefix "/" v.agePath;

  filteredMap = lib.filterAttrs (_: v: validEntry v) rawMap;

  mkSecret = name: v: {
    file  = v.agePath;
    mode  = if v ? mode  then v.mode  else "0400";
    owner = if v ? owner then v.owner else "root";
    group = if v ? group then v.group else "root";
  }
  // lib.optionalAttrs (v ? path)    { path = v.path; }
  // lib.optionalAttrs (v ? symlink) { symlink = v.symlink; }
  // lib.optionalAttrs (v ? name)    { name = v.name; };

  secrets = lib.mapAttrs mkSecret filteredMap;

  secretsctl = pkgs.writeShellApplication {
    name = "secretsctl";
    runtimeInputs = [
      pkgs.age pkgs.jq pkgs.gnutar pkgs.util-linux pkgs.coreutils pkgs.gnused pkgs.moreutils pkgs.findutils
    ];
    text = builtins.readFile ./tools/secretsctl;
  };
in {
  age = {
    identityPaths = [ "/etc/agenix/key.txt" ];
    secrets = secrets;
  };

  environment.systemPackages = [ secretsctl ];

  systemd.tmpfiles.rules = [
    "d /etc/agenix 0700 root root - -"
    "d /var/lib/agenix 0700 root root - -"
    # Example placeholder of an empty map (not installed by default):
    # "f /srv/nixserver/manifests/secrets-map.json 0644 root root - { version = 1; secrets = {}; }"
  ];

  assertions = [{
    assertion = true;
    message = "secrets.nix: secrets map provided by flake; invalid entries are ignored.";
  }];
}
