# =========================
# security.nix
# =========================
# --- SECURITY SERVICES, FIREWALL, HARDENING ---
# Manages secret/service dependencies, fail2ban, AV, firewall, crowdsec.
# For CrowdSec, community module does not support the 'localApi' NixOS option.
# Instead, local API is enabled by providing a suitable config.yaml.
# ------------------------------------------------

{ config, pkgs, ... }:

{
#better formatting needs happen for openssh bit
services.openssh = {
enable = true;
settings = {
PermitRootLogin = "no";
PasswordAuthentication = false;
KbdInteractiveAuthentication = false;
};};


  # --- ALL SECRET MANAGEMENT via ensure-secrets.service ---
  # Any security or service module should depend on secrets being present at their /run/agenix/ paths.

  # --- FAIL2BAN: SSH AND BRUTE-FORCE PROTECTION ---
  services.fail2ban.enable = true;

  # --- CLAMAV: ANTIVIRUS DAEMON AND UPDATER ---
  services.clamav.daemon.enable = true;
  services.clamav.updater.enable = true;

  # --- FIREWALL: BASIC IPV4/6 FILTERING ---
  networking.firewall.enable = true;

  # Global allowances (host services)
  networking.firewall.allowedTCPPorts = [ 22 80 443 ]; # SSH/HTTP/HTTPS
  networking.firewall.allowedUDPPorts = [ 53 ];        # DNS

  # --- ISCSI/NAS LINK POLICY (INTERFACE-SPECIFIC) ---
  # Only allow iSCSI (TCP/3260) on the dedicated /30 VLAN interface, from the /30 subnet.
  networking.firewall.interfaces.naslink.allowedTCPPorts = [ 3260 ];

  # nftables rules to strictly limit naslink: permit 3260 from /30, then drop everything else on that interface.
  networking.firewall.extraInputRules = ''
    iifname "naslink" tcp dport 3260 ip saddr 10.250.250.248/30 accept
    iifname "naslink" drop
  '';

  # --- SUDO: PASSWORDLESS SUDO FOR NIXUSER (commented) ---
  security.sudo = {
    enable = true;
    wheelNeedsPassword = false;
  }; 

  # --- CROWDSEC: BEHAVIORAL DETECTION & LOCAL API ---
  services.crowdsec = {
    enable = true;
    # No 'localApi' option here. Local API is enabled by providing a correct config.yaml.
  };

  # --- CROWDSEC CONFIGURATION MANAGEMENT ---
  environment.etc."crowdsec/config.yaml".source = ./crowdsec-config.yaml;

  # --- SECRETS DEPENDENCY NOTE ---
  # If you have security services that require secrets, ensure their systemd units use:
  # after = [ "ensure-secrets.service" ];
}
