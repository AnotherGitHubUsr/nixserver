# =========================
# pkgs.nix
# =========================
# --- PACKAGES, SERVICES, TAILSCALE, FLATPAK, GRAPHICS ---
# Stable core pkgs with optional unstable via pkgsUnstable.
# Tailscale uses auth key only for initial login; accepts routes; no subnet advertising.
# Flatpak enabled. Headless-friendly.
# Graphics: hardware.graphics on NixOS 25.05.
# --------------------------------------------------------

{ config, pkgs, pkgsUnstable, lib ? pkgs.lib, ... }:

{
  # --- NIX PATH CHANNELS (FOR SHELLS/LEGACY) ---
  nix.nixPath = [
    "nixpkgs=${pkgs.path}"
    "nixos-unstable=${pkgsUnstable.path}"
  ];

  # --- CORE SYSTEM PACKAGES ---
  environment.systemPackages = with pkgs; [
    vim                  # text editor
    wget                 # HTTP/FTP downloader
    git                  # version control
    flatpak              # Flatpak CLI/runner (mgr lives in module below)
    docker               # Docker CLI (engine configured via virtualisation.docker)
    mergerfs             # FUSE union filesystem tool
    gh                   # GitHub CLI
    tldr                 # concise manpage summaries
    tailscale            # Tailscale CLI
    p7zip                # 7z archive tool
    tmux                 # terminal multiplexer
    htop                 # process viewer
    nmon                 # performance monitor
    fish                 # alternative shell
    nushell              # structured-data shell
    bcachefs-tools       # bcachefs userspace utilities
    openiscsi            # iSCSI initiator tools
    gptfdisk             # sgdisk/gdisk partitioning
    parted               # GNU partitioning tool
    e2fsprogs            # ext2/3/4 mkfs/fsck/tools
    exfatprogs           # exFAT mkfs/fsck/label tools
    dosfstools           # FAT/VFAT mkfs/label tools
    zfs                  # ZFS userland (zpool/zfs); kernel enabled elsewhere
    jq                   # JSON processor
    python3              # Python runtime for helper scripts
    python3Packages.tomli # TOML parser fallback for <3.11 environments
    util-linux           # lsblk/findmnt/blkid/column etc.
    iperf3               # network throughput tester
    age                  # age + age-keygen (encryption)
    openssl              # crypto utils; passwd -6 (sha512-crypt)
    whois                # provides mkpasswd (yescrypt)
    apacheHttpd          # provides htpasswd (bcrypt/basic-auth)
    gnutar               # GNU tar (export/import archives)
    moreutils            # sponge et al. for safe in-place edits
    coreutils            # GNU core utilities
    findutils            # find/xargs
    gnused               # GNU sed
    shellcheck           # shell linter
    shfmt                # shell formatter
    file                 # file(1) type inspector
  ];

  # Use the module for nix-ld so non-Nix binaries can resolve libs at runtime.
  programs.nix-ld.enable = true;

  # --- TAILSCALE VPN SETUP ---
  services.tailscale =
    {
      enable = true;
      useRoutingFeatures = "client";   # accept routes, do not advertise
      extraUpFlags = [
        "--hostname=nixserver"
        "--ssh"
        "--accept-routes"
        "--advertise-tags=tag:nixserver"
      ];
    }
    // lib.optionalAttrs (config.age.secrets ? "tailscale-authkey") {
      authKeyFile = config.age.secrets."tailscale-authkey".path;  # initial auth only
    };

  # --- FLATPAK (HEADLESS-FRIENDLY) ---
  services.flatpak.enable = true;
  # Optional declarative Flathub remote:
  # services.flatpak.remotes = [
  #   { name = "flathub"; location = "https://flathub.org/repo/flathub.flatpakrepo"; }
  # ];

  # Minimal portal to satisfy Flatpak expectations.
  xdg.portal = {
    enable = true;
    extraPortals = [ pkgs.xdg-desktop-portal-gtk ];
  };

  # --- HARDWARE (AMD RYZEN & RADEON RX 6600) ---
  hardware.cpu.amd.updateMicrocode = true;

  hardware.graphics = {
    enable = true;
    enable32Bit = true;                 # 32-bit GL/Vulkan for Wine/Proton
    extraPackages = with pkgs; [
      amdvlk                           # AMD Vulkan ICD (RADV remains default)
      vaapiVdpau                       # VA-API ↔ VDPAU translation
    ];
    # extraPackages32Bit = with pkgs.pkgsi686Linux; [ amdvlk ];
  };

  # --- DOCKER ENGINE ---
  virtualisation.docker = {
    enable = true;
    daemon.settings = {
      "log-driver" = "json-file";
      "log-opts" = { "max-size" = "10m"; "max-file" = "3"; };
    };
    autoPrune = {
      enable = true;
      dates = "weekly";
      flags = [ "--all" "--volumes" ];
    };
  };

  # --- DECLARATIVE OCI CONTAINERS (backend: Docker) ---
  virtualisation.oci-containers = {
    backend = "docker";  # must match enabled runtime
    containers = {
      portainer = {
        image = "portainer/portainer-ce:latest";
        autoStart = true;
        ports = [ "9443:9443" ];
        volumes = [
          "/var/lib/portainer:/data"
          "/var/run/docker.sock:/var/run/docker.sock"
        ];
      };

      dockge = {
        image = "louislam/dockge:latest";
        autoStart = true;
        ports = [ "5001:5001" ];
        volumes = [
          "/var/lib/dockge:/app/data"
          "/var/run/docker.sock:/var/run/docker.sock"
        ];
        environment = { DOCKGE_LOG_LEVEL = "info"; };
      };
    };
  };

  # Persistent data dirs for containers.
  systemd.tmpfiles.rules = [
    "d /var/lib/portainer 0750 root root - -"
    "d /var/lib/dockge    0750 root root - -"
  ];
}
