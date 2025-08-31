# ==============================================================================
# disk.nix — Declarative filesystems from a host-local manifest
# ------------------------------------------------------------------------------
# Schema (array of objects):
#   [
#     { "mountPoint": "/", "device": "/dev/disk/by-uuid/…", "fsType": "ext4",
#       "options": ["noatime"] },
#     { "mountPoint": "/boot", "device": "/dev/disk/by-uuid/…", "fsType": "vfat",
#       "options": ["umask=0077"] }
#   ]
#
# Notes
#   • Keep /boot mounted during rebuilds so boot entries update.
#   • No state is read from /etc; the JSON lives under /srv/nixserver/manifests
#     but is read by the flake and passed in here as data.
#   • If the JSON is missing a root entry ("/"), evaluation will fail with a
#     helpful message explaining how to generate and apply a plan.
#   • This module prefers UEFI (systemd-boot) and forcibly disables GRUB.
#
# Source of truth: manifests/filesystems.json (flake input “manifests”)
# Passed to this module as:  fsList (via flake.nix specialArgs)
# ==============================================================================

{ config, lib, pkgs, fsList ? [ ], ... }:

let
  # Validate and sanitize options vectors
  sanitizeOptions = opts:
    let list =
      if builtins.isList opts then opts else
      if builtins.isString opts then [ opts ] else [ ];
    in builtins.filter (x: builtins.isString x && x != "") list;

  # Build an attrset { "/mnt" = { device=..; fsType=..; options=[..]; } ; ... }
  fsAttrset =
    builtins.listToAttrs (map
      (fs:
        let
          mp   = fs.mountPoint or (throw "filesystems.json: entry without mountPoint");
          dev  = fs.device     or (throw "filesystems.json: ${mp}: missing device");
          typ  = fs.fsType     or (throw "filesystems.json: ${mp}: missing fsType");
          opts = sanitizeOptions (fs.options or [ ]);
          val  = { device = dev; fsType = typ; }
                 // (if (builtins.length opts) > 0 then { options = opts; } else { });
        in { name = mp; value = val; }
      )
      fsList);

  haveRoot = fsAttrset ? "/";
in
{
  # Strong, early error if root is missing; include precise guidance.
  assertions = [
    {
      assertion = (builtins.length fsList) > 0;
      message = ''
        fsList from flake is empty.
        If you edited /srv/nixserver/manifests/filesystems.json, refresh the lock:
          nix flake update manifests
        Then rebuild:
          sudo nixos-rebuild switch --flake /srv/nixserver#nixserver
      '';
    }
    {
      assertion = haveRoot;
      message = ''
        No device specified for mount point "/".
        The manifest (flake input) does not contain a root entry.

        If you edited /srv/nixserver/manifests/filesystems.json, refresh the lock:
          nix flake update manifests
        Then rebuild:
          sudo nixos-rebuild switch --flake /srv/nixserver#nixserver
      '';
    }
  ];

  # Declarative filesystems from manifest
  fileSystems =
    fsAttrset
    // (lib.optionalAttrs haveRoot {
      # Deep-merge into "/" instead of replacing it, so device/fsType are kept.
      "/" =
        (fsAttrset."/")
        // {
          # ensure noatime is retained/added for root unless already present
          options =
            let existing = (fsAttrset."/".options or [ ]);
            in existing ++ (if lib.elem "noatime" existing then [ ] else [ "noatime" ]);

          # Mark root as required in stage-1
          neededForBoot = true;
        };
    });

  # Prefer UEFI (systemd-boot); make sure GRUB is off to silence GRUB assertions.
  boot.loader = {
    grub.enable = lib.mkForce false;
    systemd-boot.enable = lib.mkDefault true;
    efi.canTouchEfiVariables = lib.mkDefault true;
  };
}