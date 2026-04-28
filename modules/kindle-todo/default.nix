{ config, pkgs, lib, ... }:

let
  todoPython = pkgs.python3.withPackages (ps: with ps; [
    flask
    requests
    icalendar
    pillow
  ]);

  todoServer = pkgs.writeScriptBin "todos-server" ''
    #!${todoPython}/bin/python3
    ${builtins.readFile ./todos-server.py}
  '';
in {
  systemd.services.todos-server = {
    description = "Nextcloud TODOs → Kindle PNG server";
    after       = [ "network-online.target" ];
    wants       = [ "network-online.target" ];
    wantedBy    = [ "multi-user.target" ];

    environment = {
      FONT_PATH = "${pkgs.dejavu_fonts}/share/fonts/truetype/";
      NC_URL = "https://nextcloud.${config.common.domain}";
      NC_USER = "lucas";
      PORT = "8765";
    };

    serviceConfig = {
      ExecStart       = "${todoServer}/bin/todos-server";
      Restart         = "on-failure";
      RestartSec      = "5s";
      LoadCredential = "NC_PASS:${config.sops.secrets.nextcloud-todo-token.path}";
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
  networking.firewall.allowedTCPPorts = [ 8765 ];

  # ── Fonts ─────────────────────────────────────────────────────────────────
  fonts.packages = [ pkgs.dejavu_fonts ];
}