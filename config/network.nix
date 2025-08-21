# =========================
# network.nix
# =========================
# --- NETWORKING, TIMEZONE, INTERFACES, SUBNETS ---
# Sets hostname, static IP, DNS, NTS NTP (via chrony), and special /30 subnet for NAS.
# -------------------------------------------------

{ lib, config, pkgs, ... }:

{
  # --- HOSTNAME & TIME ---
  networking.hostName = "nixserver";
  time.timeZone = "Europe/Berlin";        # Standard for ME(S)T

  # --- NTP SERVERS (WITH NTS SUPPORT, VIA CHRONY) ---
  # The systemd-timesyncd backend does not support NTS as of NixOS 24.05+.
  # chrony is used for secure, authenticated NTP (NTS).
# chrony with nts made waaay too many problems. maybe re-add in the fututre
  services.timesyncd = {
    enable = true;
    servers = [
      "time.metrologie.at"
      "ptbtime1.ptb.de"
      "time2.ethz.ch"
    ];
    # fallbackServers = [ "pool.ntp.org" ];
  };

  # --- PRIMARY ETHERNET INTERFACE (STATIC) ---
  networking.interfaces.enp4s0 = {
    ipv4.addresses = [{ address = "192.168.1.3"; prefixLength = 24; }];
  };
  networking.defaultGateway = "192.168.1.1";
  networking.nameservers = [
    "192.168.1.50" # Pihole (local DNS)
    "9.9.9.9"      # Quad9 (public DNS)
  ];

  # --- VLAN FOR NAS /30 ON SINGLE PHYSICAL PORT (enp4s0) ---
  # Best-practice logical separation: create VLAN 'naslink' on enp4s0.
  networking.vlans.naslink = {
    id = 250;
    interface = "enp4s0";
  };

  # --- /30 SUBNET FOR NAS COMMUNICATION ONLY ---
  networking.interfaces.naslink = {
    ipv4.addresses = [{ address = "10.250.250.249"; prefixLength = 30; }];
  };
}
