# ==============================================================================
# kernel.nix — Kernel pin and ZFS integration (OpenZFS ≥ 2.3.3), plus kernel opts
# ------------------------------------------------------------------------------
# Purpose:
#   - Pin Linux kernel (6.15 by default).
#   - Enable ZFS the NixOS-native way (no extraModulePackages for ZFS).
#   - Prefer *stable* ZFS by default; fall back to unstable only if stable < 2.3.3.
#   - Provide import behavior toggles and common kernel parameters.
#
# How to modify/extend:
#   - Change kernel with `boot.kernelPackages = pkgs.linuxPackages_<ver>;`.
#   - If root is NOT on ZFS, keep `boot.zfs.forceImportRoot = false;` or omit.
#   - Set a stable 8-hex `networking.hostId` once; do not rotate it.
#
# Notable notes/policies:
#   - Avoid `boot.extraModulePackages` for ZFS. Use `boot.zfs.package` + `boot.supportedFilesystems` instead.
#   - Bcachefs is in mainline kernels; no out-of-tree module pinning is required for it.
#   - For testing unsupported kernel/ZFS combos, prefer a matching package instead of forcing ignore flags.
# ==============================================================================
 
{ pkgs
, pkgsUnstable ? null
, lib ? pkgs.lib
, ...
}:
 
let
  # Resolve a ZFS package with this preference order:
  #   1) Stable channel (pkgs.zfs) if version ≥ 2.3.3
  #   2) Stable channel (pkgs.zfs_2_3) if present
  #   3) Unstable (pkgsUnstable.zfs_2_3 or pkgsUnstable.zfs or pkgsUnstable.zfsUnstable)
  #   4) Fallback to pkgs.zfs
  zfsPkg = let
    stableHas = pkgs ? zfs;
    stableVer = if stableHas then (pkgs.zfs.version or "0") else "0";
    stableGe233 = builtins.compareVersions stableVer "2.3.3" >= 0;
    unstableChoice =
      if pkgsUnstable == null then null else
      if pkgsUnstable ? zfs_2_3 then pkgsUnstable.zfs_2_3 else
      if pkgsUnstable ? zfs then pkgsUnstable.zfs else
      if pkgsUnstable ? zfsUnstable then pkgsUnstable.zfsUnstable else
      null;
  in
    if stableHas && stableGe233 then pkgs.zfs
    else if pkgs ? zfs_2_3 then pkgs.zfs_2_3
    else if unstableChoice != null then unstableChoice
    else pkgs.zfs;
in
{
  # ------------------------------
  # Kernel selection
  # ------------------------------
  boot.kernelPackages = pkgs.linuxPackages_6_15;
  # Alternative (newer kernel; ensure ZFS supports it first):
  # boot.kernelPackages = pkgs.linuxPackages_latest;
 
  # ------------------------------
  # ZFS (bcachefs) enablement (NixOS-native)
  # ------------------------------
  boot.supportedFilesystems = [ "zfs" /*"bcachefs" if needed because kernel updated to drop it*/ ];
  boot.zfs.package = zfsPkg;
 
  # Import behavior:
  # - Keep forceImportRoot false if root is not on ZFS.
  # - Consider forceImportAll=true for single-host pools to import despite host-ID mismatches.
  boot.zfs.forceImportRoot = lib.mkDefault false;
  boot.zfs.forceImportAll  = lib.mkDefault false;
 
  # REQUIRED for ZFS pool import coordination.
  networking.hostId = lib.mkDefault "421b173a";  # `head -c8 /etc/machine-id`
 
  # ------------------------------
  # Early kernel modules
  # ------------------------------
  boot.kernelModules = [
    "iscsi_tcp"            # iSCSI transport for SAN/NAS-backed LUNs
  ];
 
  # ------------------------------
  # Kernel parameters
  # ------------------------------
  boot.kernelParams = [
    # ZFS: allow loading with newer kernels if absolutely necessary.
    # Prefer matching zfs package over this escape hatch.
    # "zfs.zfs_allow_unsupported=1"
 
    # Block-cache (classic bcache) example flag (uncomment only if you use bcache):
    # "bcache.allow_across_disks=1"
 
    # Virtualization / passthrough:
    "amd_iommu=on"
    "iommu=pt"
  ];
}
