{
  config,
  lib,
  pkgs,
  utils,
  ...
}:
let
  homelab = import ../lib {
    inherit config;
    inherit lib;
  };

  domain = config.common.internalDomain;
  forgejoDomain = "forgejo.${domain}";
  runnerInstanceName = "forgejo-local";
  # The token gets its own runtime directory (not inside /run/forgejo, which
  # systemd removes whenever the forgejo service restarts and is only
  # regenerated once per boot).
  runnerTokenDir = "forgejo-runner-token";
  runnerTokenFile = "/run/${runnerTokenDir}/token";
  # nixpkgs' gitea-actions-runner instance module names its systemd unit
  # "gitea-runner-${escapeSystemdPath <instance-name>}", i.e. the instance
  # "forgejo-local" becomes the unit "gitea-runner-forgejo\x2dlocal.service".
  # Derive the name the same way here, so the override below hits the
  # generated unit instead of creating a second, empty one (which systemd
  # refuses to start: "Service has no ExecStart=").
  runnerUnitName = "gitea-runner-${utils.escapeSystemdPath runnerInstanceName}";
in
{
  # The msmtp/SMTP password secret is group-readable by "sendmail", so the
  # forgejo user must be a member to let msmtp fetch the credentials.
  users.groups.sendmail.members = [
    "forgejo"
  ];

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
        SSH_PORT = lib.head config.services.openssh.ports;
      };
      service = {
        DISABLE_REGISTRATION = false;
      };
      # Send transactional mail (registration, notifications, ...) through the
      # host's system sendmail, i.e. the msmtp wrapper configured in
      # modules/homelab.nix, matching nextcloud and vaultwarden.
      mailer = {
        ENABLED = true;
        PROTOCOL = "sendmail";
        FROM = "server@romeromail.de";
        SENDMAIL_PATH = "${pkgs.system-sendmail}/bin/sendmail";
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
    instances.${runnerInstanceName} = {
      enable = true;
      name = "forgejo-local";
      # forgejo-runner speaks plain HTTP(S) only: its HTTP client has no
      # unix-socket support, so "http://unix:/run/forgejo/forgejo.sock" is
      # parsed as the DNS host "unix" and registration fails
      # ("Cannot ping the Forgejo instance server: lookup unix: no such
      # host"). Point it at the local nginx vhost that fronts the unix
      # socket instead.
      url = "https://${forgejoDomain}";
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
    wantedBy = [ "multi-user.target" ];
    # The forgejo CLI refuses to run as root ("Forgejo is not supposed to be
    # run as root") and needs these to locate its app.ini and postgres
    # database. Run it as the forgejo user with the same environment the
    # forgejo service itself uses.
    environment = {
      USER = config.services.forgejo.user;
      HOME = config.services.forgejo.stateDir;
      FORGEJO_WORK_DIR = config.services.forgejo.stateDir;
      FORGEJO_CUSTOM = config.services.forgejo.customDir;
    };
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      User = config.services.forgejo.user;
      Group = config.services.forgejo.group;
      RuntimeDirectory = runnerTokenDir;
      UMask = "0077";
    };
    script = ''
      set -euo pipefail
      # Wait for the unix socket to be ready
      ready=""
      for i in $(seq 1 30); do
        if ${pkgs.netcat-openbsd}/bin/nc -z -U ${config.services.forgejo.settings.server.HTTP_ADDR} 2>/dev/null; then
          ready=1
          break
        fi
        echo "Waiting for Forgejo socket..."
        sleep 2
      done
      if [ -z "$ready" ]; then
        echo "Forgejo socket never became ready; giving up." >&2
        exit 1
      fi
      sleep 2
      TOKEN=$(${config.services.forgejo.package}/bin/forgejo actions generate-runner-token)
      echo -n "TOKEN=$TOKEN" > ${runnerTokenFile}
      chmod 600 ${runnerTokenFile}
    '';
  };

  # Ensure the runner waits for token generation, and for nginx (the runner
  # reaches forgejo through the https vhost nginx terminates).
  systemd.services.${runnerUnitName} = {
    after = [
      "forgejo-runner-token.service"
      "nginx.service"
    ];
    wants = [
      "forgejo-runner-token.service"
      "nginx.service"
    ];
  };

  # --- Nginx reverse proxy ---
  services.nginx.virtualHosts.${forgejoDomain} = homelab.mkVirtualHost {
    port = null; # Using unix socket
    internal = true;
    settings = {
      proxyPass = "http://unix:${config.services.forgejo.settings.server.HTTP_ADDR}";
    };
  };
}
