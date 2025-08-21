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
#   • This module reads /etc/agenix/secrets-map.json at EVAL time.
#   • Valid entries (name → { agePath, mode?, owner?, group? }) are turned into
#     agenix secrets. At ACTIVATE, Agenix decrypts to /run/agenix/<name>.
#   • If the map file is missing, evaluation still succeeds (empty map).
#
# Notes / best practices
#   • Do NOT read decrypted secrets with builtins.readFile (would leak to store).
#   • Services should consume files via:  config.age.secrets.<name>.path
#   • Create/rename/remove secrets with the companion CLI: `secretsctl`.
# ------------------------------------------------------------------------------

{ config, lib, pkgs, manifestsPath ? "/srv/nixserver/manifests", ... }:
let
  mapPath = "${manifestsPath}/secrets-map.json";
  secretsMap =
    if builtins.pathExists mapPath
    then builtins.fromJSON (builtins.readFile mapPath)
    else { version = 1; secrets = {}; };

  validEntry = v:
    (builtins.isAttrs v)
    && (v ? agePath)
    && (builtins.isString v.agePath)
    && lib.hasPrefix "/" v.agePath;

  filteredMap = lib.filterAttrs (_: v: validEntry v) rawMap;

  mkSecret = name: v:
    {
      file  = v.agePath;                        # absolute path to .age blob
      mode  = if v ? mode  then v.mode  else "0400";
      owner = if v ? owner then v.owner else "root";
      group = if v ? group then v.group else "root";
      # Optional passthroughs if you decide to add them to the map later:
    }
    // lib.optionalAttrs (v ? path)    { path = v.path; }
    // lib.optionalAttrs (v ? symlink) { symlink = v.symlink; }
    // lib.optionalAttrs (v ? name)    { name = v.name; };

  secrets = lib.mapAttrs mkSecret filteredMap;

  # Ship the CLI on PATH. The script file `./secretsctl` sits next to this file.
  secretsctl = pkgs.writeShellApplication {
    name = "secretsctl";
    runtimeInputs = [
      pkgs.age           # provides age + age-keygen
      pkgs.jq
      pkgs.gnutar        # tar
      pkgs.util-linux    # flock
      pkgs.coreutils
      pkgs.gnused
      pkgs.moreutils     # sponge
      pkgs.findutils
    ];
    text = builtins.readFile ./secretsctl;
  };
in {
  # Agenix: use a dedicated Age identity (not SSH host keys)
  age = {
    identityPaths = [ "/etc/agenix/key.txt" ];  # string paths to private keys on the host
    secrets = secrets;                           # from the filtered map
    # FYI defaults: secretsDir=/run/agenix, secretsMountPoint=/run/agenix.d
  };

  # Put our CLI on PATH for convenience
  environment.systemPackages = [ secretsctl ];

  # Ensure directories exist with correct perms at boot (no plaintext!)
  systemd.tmpfiles.rules = [
    "d /etc/agenix 0700 root root - -"
    "d /var/lib/agenix 0700 root root - -"
    # Optionally ensure the map exists as an empty JSON object:
    # "f /srv/nixserver/manifests/secrets-map.json 0644 root root - { version = 1; secrets = {}; }"
  ];

  # Keep evaluation resilient; any invalid entries are ignored above.
  assertions = [
    {
      assertion = true;
      message = "secrets.nix: secrets map is host-local; invalid entries are ignored.";
    }
  ];
}

