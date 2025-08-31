# ==============================================================================
# security.nix
# ------------------------------------------------------------------------------
# Configures OpenSSH, firewall, Fail2ban, ClamAV, and CrowdSec (agent + LAPI).
# Extend by: adding more acquisitions under /etc/crowdsec/acquis.d and extra
#            cscli collections in the pre-start helper below.
# Notable paths/policies (this repo):
#  - CrowdSec data/db:  /var/lib/crowdsec/{hub,data,crowdsec.db}
#  - CrowdSec runtime:  /run/crowdsec
#  - Acquisitions dir:  /etc/crowdsec/acquis.d
#  - Journald access:   service user joins systemd-journal group
# ==============================================================================

{ config, pkgs, lib, ... }:

let
  # Ensure hub content (parsers/scenarios) exists every start/restart.
  crowdsecPrepare = pkgs.writeShellApplication {
    name = "crowdsec-prepare";
    runtimeInputs = [ pkgs.crowdsec pkgs.jq ];
    text = ''
      set -euo pipefail
      ${pkgs.crowdsec}/bin/cscli hub update
      if ! ${pkgs.crowdsec}/bin/cscli collections list -o json | jq -e '.collections[]?.name=="crowdsecurity/linux"' >/dev/null; then
        ${pkgs.crowdsec}/bin/cscli collections install crowdsecurity/linux
      fi
      if ! ${pkgs.crowdsec}/bin/cscli collections list -o json | jq -e '.collections[]?.name=="crowdsecurity/sshd"' >/dev/null; then
        ${pkgs.crowdsec}/bin/cscli collections install crowdsecurity/sshd
      fi
    '';
  };

  # Minimal journald acquisition for sshd; written via environment.etc
  sshAcquis = ''
    # Read sshd messages from systemd-journal
    source: journalctl
    journalctl_filter:
      - "_SYSTEMD_UNIT=sshd.service"
    labels:
      type: syslog
  '';
in
{
  # --- OpenSSH (hardened defaults) ---
  services.openssh = {
    enable = true;
    settings = {
      PermitRootLogin = "no";
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
    };
  };

  # --- Fail2ban / ClamAV ---
  services.fail2ban.enable = true;
  services.clamav = {
    daemon.enable = true;
    updater.enable = true;
  };

  # --- Firewall ---
  networking.firewall = {
    enable = true;
    allowedTCPPorts = [ 22 80 443 ];
    allowedUDPPorts = [ 53 ];
    interfaces.naslink.allowedTCPPorts = [ 3260 ];
    extraInputRules = ''
      iifname "naslink" tcp dport 3260 ip saddr 10.250.250.248/30 accept
      iifname "naslink" drop
    '';
  };

  # --- CrowdSec agent (no bouncer here) ---
  services.crowdsec = {
    enable = true;

    # v1.6+ config expressed declaratively. The module will render /etc/crowdsec/config.yaml.
    settings = {
      common = {
        pid_dir = "/run/crowdsec";
        log_media = "stdout";
        log_level = "info";
      };
      config_paths = {
        config_dir = "/etc/crowdsec";
        data_dir   = "/var/lib/crowdsec";
        hub_dir    = "/var/lib/crowdsec/hub";
        index_path = "/var/lib/crowdsec/hub/.index.json";
      };
      db_config = {
        type    = "sqlite";
        db_path = "/var/lib/crowdsec/crowdsec.db";
        use_wal = true;
      };
      api.server = {
        enable = true;
        listen_uri = "127.0.0.1:8080";
        log_level  = "info";
      };
      crowdsec_service.acquisition_dir = "/etc/crowdsec/acquis.d";

      # Keep GeoIP enrichers off unless mmdb is provided later under /var/lib/crowdsec/data.
      plugin_config.enrich.geoip = { enabled = false; };
    };
  };

  # Pre-start to ensure hub content is installed; idempotent.
  systemd.services.crowdsec.serviceConfig.ExecStartPre = [
    "${crowdsecPrepare}/bin/crowdsec-prepare"
  ];

  # Allow the service to read the journal via the group.
  systemd.services.crowdsec.serviceConfig.SupplementaryGroups = [ "systemd-journal" ];

  # Acquisition file: journald → sshd unit filter.
  environment.etc."crowdsec/acquis.d/ssh.yaml" = {
    text = sshAcquis;
    mode = "0644";
  };

  # Runtime/data dirs and ownership for the service user.
  systemd.tmpfiles.rules = [
    "d /run/crowdsec          0750 crowdsec crowdsec - -"
    "d /var/lib/crowdsec      0750 crowdsec crowdsec - -"
    "d /var/lib/crowdsec/data 0750 crowdsec crowdsec - -"
    "d /var/lib/crowdsec/hub  0750 crowdsec crowdsec - -"
  ];
}
