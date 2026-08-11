{
  config,
  lib,
  pkgs,
  ...
}:
let
  utils = import ../lib {
    inherit config;
    inherit lib;
  };

  domain = config.common.domain;
  forgejoDomain = "forgejo.${domain}";
  runnerTokenFile = "/run/forgejo/forgejo-runner-token";

  # --- Forgejo service ---
  services.forgejo = {
    enable = true;
    database = {
      type = "postgres";
      host = "/var/run/postgresql";
      name = "forgejo";
      user = "forgejo";
    };
    settings = {
      server = {
        DOMAIN = domain;
        ROOT_URL = "https://${forgejoDomain}/";
        HTTP_ADDR = "/run/forgejo/forgejo.sock";
        PROTOCOL = "http+unix";
      };
      service = {
        DISABLE_REGISTRATION = false;
      };
      actions = {
        ENABLED = true;
        DEFAULT_ACTIONS_URL = "github";
      };
      log = {
        LEVEL = "Info";
      };
      cron = {
        ENABLE = true;
        RUN_AT_START = true;
        SCHEDULE = "@every 1h";
      };
    };
  };

  # --- Forgejo self-hosted runner ---
  services.gitea-actions-runner = {
    package = pkgs.forgejo-runner;
    instances.forgejo-local = {
      enable = true;
      name = "forgejo-local";
      url = "http://unix:${config.services.forgejo.settings.server.HTTP_ADDR}";
      tokenFile = runnerTokenFile;
      labels = [
        "native:host"
      ];
      hostPackages = with pkgs; [
        bash
        coreutils
        curl
        gawk
        gitMinimal
        gnused
        nodejs
        wget
      ];
    };
  };

  # --- Runner token generation ---
  # Wait for Forgejo to be up, then generate a runner token.
  systemd.services.forgejo-runner-token = {
    description = "Generate Forgejo runner registration token";
    after = [ "forgejo.service" ];
    wants = [ "forgejo.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "forgejo-runner-token.sh" ''
        set -euo pipefail
        # Wait for the unix socket to be ready
        for i in $(seq 1 30); do
          if ${pkgs.netcat-openbsd}/bin/nc -z -U ${config.services.forgejo.settings.server.HTTP_ADDR} 2>/dev/null; then
            break
          fi
          echo "Waiting for Forgejo socket..."
          sleep 2
        done
        sleep 2
        TOKEN=$(${config.services.forgejo.package}/bin/forgejo actions generate-runner-token)
        mkdir -p /run/forgejo
        echo -n "TOKEN=$TOKEN" > ${runnerTokenFile}
        chmod 600 ${runnerTokenFile}
      '';
    };
  };

  # Ensure runner waits for token generation
  systemd.services.gitea-runner-forgejo-local = {
    after = [ "forgejo-runner-token.service" ];
    wants = [ "forgejo-runner-token.service" ];
  };

  # --- Nginx reverse proxy ---
  services.nginx.virtualHosts.${forgejoDomain} = utils.mkVirtualHost {
    port = null; # Using unix socket
    internal = false;
    settings = {
      proxyPass = "http://unix:${config.services.forgejo.settings.server.HTTP_ADDR}";
      proxySetHeaders = {
        Host = "$host";
        X-Real-IP = "$remote_addr";
        X-Forwarded-For = "$proxy_add_x_forwarded_for";
        X-Forwarded-Proto = "$scheme";
      };
    };
  };
}
