{
  config,
  lib,
  pkgs,
  ...
}:
let
  dawarichDomain = "dawarich.${config.common.domain}";
  dawarichAdminEmail = "lucas@romeromail.de";

  # The module's default web port (3000) is already used by Grafana on
  # elserver, so give Dawarich its own loopback port.
  dawarichHttpPort = 3010;

  # `rails db:seed` creates `demo@dawarich.app` / `safepassword` when the user
  # table is empty. Rename it to a real account and give it a generated
  # password right after the first seed, so a freshly deployed public instance
  # never accepts the well-known demo credentials.
  dawarichAdminBootstrap = pkgs.writeText "dawarich-admin-bootstrap.rb" ''
    demo = User.find_by(email: "demo@dawarich.app")
    if demo
      demo.update!(
        email: ENV.fetch("DAWARICH_ADMIN_EMAIL"),
        password: ENV.fetch("DAWARICH_ADMIN_PASSWORD"),
        password_confirmation: ENV.fetch("DAWARICH_ADMIN_PASSWORD"),
        admin: true,
        status: :active,
        active_until: 100.years.from_now
      )
      puts "Dawarich: replaced the seeded demo admin with #{demo.email}"
    end
  '';
in
{
  clan.core.vars.generators.dawarich-secret-key-base = {
    files."secret-key-base".secret = true;
    runtimeInputs = [ pkgs.openssl ];
    script = ''
      openssl rand -hex 64 > "$out/secret-key-base"
    '';
  };

  clan.core.vars.generators.dawarich-admin-password = {
    files.password.secret = true;
    runtimeInputs = [ pkgs.openssl ];
    script = ''
      openssl rand -base64 24 > "$out/password"
    '';
  };

  services.dawarich = {
    enable = true;

    webPort = dawarichHttpPort;
    localDomain = dawarichDomain;

    # Keep the Rails secret key stable across rebuilds and deploys instead of
    # letting the module generate a file inside the data directory.
    secretKeyBaseFile =
      config.clan.core.vars.generators.dawarich-secret-key-base.files."secret-key-base".path;

    # nginx is configured below instead of by the module, so the vhost gets
    # the shared wildcard ACME certificate (the module's own vhost is HTTP).
    configureNginx = false;

    environment = {
      # TLS terminates at nginx, so have Rails generate https:// links.
      APPLICATION_PROTOCOL = "https";
      # Self-hosted default, but pin it: there should be no public sign-ups.
      ALLOW_EMAIL_PASSWORD_REGISTRATION = "false";
      # Port 465 implies implicit TLS; ask Ruby to verify the upstream cert.
      SMTP_OPENSSL_VERIFY_MODE = "peer";
    };

    # Reuse the upstream SMTP account already configured for msmtp (the same
    # one immich uses), so password-reset/invitation emails leave the host.
    smtp = {
      host = config.programs.msmtp.accounts.default.host;
      port = config.programs.msmtp.defaults.port;
      fromAddress = config.programs.msmtp.accounts.default.from;
      user = config.programs.msmtp.accounts.default.user;
      passwordFile = config.sops.secrets.sendgrid-password.path;
    };

    # Reuse the existing PostgreSQL instance (the module creates the
    # `dawarich` role/database and enables PostGIS) and run a dedicated Redis
    # server on a Unix socket.
    database.createLocally = true;
    redis.createLocally = true;
  };

  # Runs in the same environment as `dawarich-init-db` (right after its
  # migrations/seeds) and replaces the seeded demo account. The generated
  # password is a systemd credential; see `dawarich-admin-password` above.
  # Retrieve it with:
  #   clan vars get elserver dawarich-admin-password/password
  systemd.services.dawarich-init-db = {
    serviceConfig.LoadCredential = lib.mkAfter [
      "dawarich_admin_password:${config.clan.core.vars.generators.dawarich-admin-password.files.password.path}"
    ];
    postStart = ''
      export SECRET_KEY_BASE="$(systemd-creds cat SECRET_KEY_BASE)"
      DAWARICH_ADMIN_EMAIL=${lib.escapeShellArg dawarichAdminEmail} \
      DAWARICH_ADMIN_PASSWORD="$(systemd-creds cat dawarich_admin_password)" \
      ${lib.getExe' config.services.dawarich.package "rails"} runner ${dawarichAdminBootstrap}
    '';
  };

  services.nginx.virtualHosts.${dawarichDomain} = {
    forceSSL = true;
    useACMEHost = config.common.domain;

    # Dawarich serves its static assets itself; anything that is not a file
    # under public/ is proxied to the Rails server. Websockets are used by the
    # live map/import progress views.
    root = "${config.services.dawarich.package}/public/";
    locations."/" = {
      tryFiles = "$uri @proxy";
    };
    locations."@proxy" = {
      proxyPass = "http://127.0.0.1:${toString dawarichHttpPort}";
      proxyWebsockets = true;
      recommendedProxySettings = true;
    };
  };
}
