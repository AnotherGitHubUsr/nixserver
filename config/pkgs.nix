# =========================
# pkgs.nix
# =========================
# --- PACKAGES, SERVICES, TAILSCALE, FLATPAK, GRAPHICS ---
# Stable core pkgs with optional unstable via pkgsUnstable.
# Tailscale uses auth key only for initial login; accepts routes; no subnet advertising.
# Flatpak is enabled with Flathub remote; headless-friendly.
# Hardware graphics: AMD RX 6600 best practices incl. 32-bit for Wine/Proton.
# --------------------------------------------------------

{ config, pkgs, pkgsUnstable, lib ? pkgs.lib, ... }:

{
  # --- NIX PATH CHANNELS (FOR SHELLS/LEGACY) ---
  nix.nixPath = [ "nixpkgs=${pkgs.path}" "nixos-unstable=${pkgsUnstable.path}" ];

  # --- CORE SYSTEM PACKAGES ---
  environment.systemPackages = with pkgs; [
    vim           # Editor (stable)
    wget          # Downloader
    git           # Version control
    nix-ld        # Run non-Nix binaries
    flatpak       # Flatpak manager
#    flathub       # Flathub repo
    docker        # Containers
    mergerfs      # Mergerfs support
    gh            # GitHub CLI
    tldr          # Short manpages
    tailscale     # VPN
    p7zip         # 7zip
    tmux          # Terminal multiplexer
    htop          # Resource monitor
    nmon          # Monitor
    systemd       # Service/timer writing
    fish          # Alternative shell
    nushell       # Alternative shell
    bcachefs-tools # User-space utilities for bcachefs
    openiscsi     # iSCSI initiator tools and utilities
    xdg-desktop-portal-gtk      # XDG portal implementation (required for xdg.portal.enable)
    gptfdisk     # Partitioning (provides sgdisk/gdisk)
    parted       # Partitioning
    e2fsprogs    # ext2/3/4 tools (mkfs.ext4, e2label)
    exfatprogs   # exFAT tools (mkfs.exfat, fsck.exfat, exfatlabel)
    dosfstools   # FAT/VFAT tools (mkfs.vfat, fatlabel)
    zfs          # ZFS userland (zpool, zfs)  # enable services.zfs for kernel module
    jq           # JSON processing in scripts
    python3      # interpreter for TOML→JSON
    python3Packages.tomli       # fallback parser (only needed on < 3.11)
    util-linux   #  lsblk/findmnt/blkid/column
    iperf3       # speed test between to servers
    age          # age + age-keygen (encryption)
    openssl      # passwd -6 (sha512-crypt)
    whois        # mkpasswd (yescrypt)
    apacheHttpd  # provides htpasswd (bcrypt/basic-auth lines)
    gnutar       # tar for export/import archives
    moreutils    # sponge, etc., used in JSON manifest edits
    coreutils    # sha256sum and friends
    findutils    # xargs/find (used in assorted scripts)
    gnused       # sed (explicit for script usage)
    shellcheck   # used for checking scripts
    shfmt      	 # unifying indentations
    file	 # gives the file's utility
  ];

  # --- UNSTABLE PACKAGE USAGE EXAMPLE ---
  # environment.systemPackages = with pkgsUnstable; [
  #   vim # Uncomment to use unstable vim, if you want latest features.
  # ];

  # --- TAILSCALE VPN SETUP ---
  services.tailscale =
    (
      {
        enable = true;
        useRoutingFeatures = "client"; # Accept subnet routes from another router, do not advertise any routes.
        extraUpFlags = [
          "--hostname=nixserver"
          "--ssh"
          "--accept-routes" # Add Tailscale's subnet routes to accepted routes
          "--advertise-tags=tag:nixserver"
          # no --advertise-routes here; nixserver is NOT a subnet router.
          # no --ephemeral; this is a stable node.
        ];
      }
    )
    // lib.optionalAttrs (config.age.secrets ? "tailscale-authkey") {
      # Use only for initial auth; not for periodic rotation.
      authKeyFile = config.age.secrets."tailscale-authkey".path;
    };

  # --- FLATPAK & WINE/PROTON SUPPORT (HEADLESS-FRIENDLY) ---
  services.flatpak = {
    enable = true;
    # remotes = [ { name = "flathub"; location = "https://flathub.org/repo/flathub.flatpakrepo"; } ];
  };
  environment.variables.FLATPAK_ENABLE = "1";

  # XDG portal is kept minimal just to satisfy Flatpak expectations.
  xdg.portal = {
    enable = true;
    extraPortals = [ pkgs.xdg-desktop-portal-gtk ];
  };

  # --- HARDWARE (AMD RYZEN & RADEON RX 6600) ---
  hardware.cpu.amd.updateMicrocode = true;

  # New-style graphics module (replaces hardware.opengl on recent NixOS):
  hardware.graphics = {
    enable = true;
    enable32Bit = true; # 32-bit OpenGL/Vulkan for Wine/Proton
    # Keep AMDVLK available; RADV (Mesa) stays default unless overridden per-app.
    extraPackages = with pkgs; [ amdvlk libva vaapiVdpau ];
    # extraPackages32Bit = with pkgs.pkgsi686Linux; [ amdvlk ];
  };

  # --- FIRMWARE SUPPORT ---
  hardware.firmware = [ pkgs.linux-firmware ];

  # --- DOCKER NETWORK BRIDGES & STORAGE ---
  virtualisation.docker.enable = false;
  # for build/boot issues. 
}
