{ config, pkgs, lib, ... }:

let
  todoPython = pkgs.python3.withPackages (ps: with ps; [
    flask
    ebooklib
    paramiko
  ]);

  todoServer = pkgs.writeScriptBin "tandoor-to-kindle" ''
    #!${todoPython}/bin/python3
    ${builtins.readFile ./tandoor-to-kindle.py}
  '';
in {
  systemd.services.tandoor-to-kindle-server = {
    description = "Tandoor → Kindle MOBI server";
    after       = [ "network-online.target" ];
    wants       = [ "network-online.target" ];
    wantedBy    = [ "multi-user.target" ];

    environment = {
      TANDOOR_URL = "https://recipes.${config.common.internalDomain}";
      KINDLE_HOST = "192.168.1.57";
      KINDLE_USER = "root";
#      KINDLE_KEY_PATH = config.sops.secrets.kindle-ssh-key.path;
      PORT = "8766";
    };

    serviceConfig = {
      ExecStart       = "${todoServer}/bin/tandoor-to-kindle";
      Environment = "PATH=${lib.makeBinPath [ pkgs.calibre ]}";
      Restart         = "on-failure";
      RestartSec      = "5s";
      LoadCredential = [
      "TANDOOR_TOKEN:${config.sops.secrets.tandoor-token.path}"
      "KINDLE_KEY:${config.sops.secrets.kindle-ssh-key.path}"
      ];
      # Hardening
      DynamicUser           = true;
      CapabilityBoundingSet = "";
      PrivateDevices        = true;
      ProtectHome           = true;
      ProtectSystem         = "strict";
      NoNewPrivileges       = true;
    };
  };

  # ── Firewall (open only if you need LAN access) ───────────────────────────
  networking.firewall.allowedTCPPorts = [ 8766 ];

  # ── Fonts ─────────────────────────────────────────────────────────────────
  fonts.packages = [ pkgs.dejavu_fonts ];
}