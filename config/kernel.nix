# =========================
# kernel.nix
# =========================
# --- KERNEL VERSION, MODULES, PARAMETERS ---
# Pin kernel version for stability, enable extra modules, and set boot flags for storage and virtualization.
# -------------------------------------------

{ pkgs, ... }:

{

  # --- OPTIONAL: USE UNSTABLE CHANNEL ---
  # Enable to use packages from nixpkgs-unstable (requires flakes or overlay setup).
  # pkgs = import <nixpkgs-unstable> { config.allowUnfree = true; };  # best practice: use readOnlyPkgs

  # --- KERNEL SELECTION ---
  # Pin to kernel 6.15 for stability (tested with ZFS 2.3.3 and bcache).
  boot.kernelPackages = pkgs.linuxPackages_6_15;

  # To use the latest available kernel (may break ZFS, bcache, bcachefs):
  # boot.kernelPackages = pkgs.linuxPackages_latest;

  # --- KERNEL MODULES ---
  # Add ZFS and block-level bcache/bcachefs support. (for the situation when bcachefs is dropped from the Kernel)
  boot.extraModulePackages = with pkgs.linuxPackages_6_12; [
    # openzfs_2_3_3           # Stable ZFS module known to work with 6.12 kernel.
    # bcache                # Option: enable block-level SSD caching for HDDs.
    # openzfs_latest        # Option: try latest ZFS module for newer kernels.
    # bcachefs_1_5          # Option: use bcachefs filesystem (uncomment to enable).
    # bcachefs_latest       # Option: always use latest bcachefs (if available in Nixpkgs).
    # bcachefs              # Generic bcachefs module, if defined in your Nixpkgs channel.
  ];

  # --- KERNEL MODULES (EARLY LOADED) ---
  # Load transport module for iSCSI support (required for NAS-backed LUNs).
  boot.kernelModules = [
    "iscsi_tcp"             # Enables iSCSI block transport via TCP.
  ];

  # --- KERNEL PARAMETERS ---
  # Custom flags for storage and virtualization.
  boot.kernelParams = [
    "zfs.force=1"           # Allows ZFS to run on newer/unsupported kernels.
    #"bcache.allow_across_disks=1"  # bcache: allow one SSD to cache multiple HDDs. (for block level bcache)
    "amd_iommu=on"          # Enables AMD IOMMU (for PCI passthrough, VMs).
    "iommu=pt"              # Pass-through mode for IOMMU (performance).
    # Add other kernel params here.
  ];

  # --- NOTES ---
  # - Only use both bcache and bcachefs if testing/migrating between them.
  # - If your Nixpkgs channel does not have a recent bcachefs module,
  #   consider using an overlay or building the module manually:
  #   https://github.com/koverstreet/bcachefs
}
