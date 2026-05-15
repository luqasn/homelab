{ config, pkgs, lib, ... }:

let
  utils = import ../../lib {
    inherit config;
    inherit lib;
  };
  todoPython = pkgs.python3.withPackages (ps: with ps; [
    flask
    ebooklib
    paramiko
  ]);

  todoServer = pkgs.stdenv.mkDerivation {
    name = "tandoor-to-kindle";
    src = ./.;
    nativeBuildInputs = [ pkgs.makeWrapper ];
    installPhase = ''
      mkdir -p $out/bin $out/lib/tandoor-to-kindle/templates
      cp $src/tandoor-to-kindle.py $out/lib/tandoor-to-kindle/app.py
      cp $src/templates/index.html $out/lib/tandoor-to-kindle/templates/index.html
      makeWrapper ${todoPython}/bin/python3 $out/bin/tandoor-to-kindle \
        --add-flags "$out/lib/tandoor-to-kindle/app.py"
    '';
  };
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

  services.nginx.virtualHosts."recipes-kindle.${config.common.internalDomain}" = utils.mkVirtualHost {
    port = 8766;
    internal = true;
  };

  # ── Fonts ─────────────────────────────────────────────────────────────────
  fonts.packages = [ pkgs.dejavu_fonts ];
}