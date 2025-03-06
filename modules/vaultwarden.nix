{
  config,
  pkgs,
  lib,
  ...
}:
let
  vaultwardenDomain = "vault.${config.common.domain}";
in
{

  users.groups.sendmail.members = [
    "vaultwarden"
  ];

  services.vaultwarden = {
    enable = true;
    dbBackend = "postgresql";
    config = {
      DOMAIN = "https://${vaultwardenDomain}";
      ROCKET_ADDRESS = "127.0.0.1";
      ROCKET_PORT = 8222;

      ROCKET_LOG = "critical";

      USE_SENDMAIL = true;
      SMTP_FROM = "server@romeromail.de";
      SMTP_FROM_NAME = "Vaultwarden server";
      DATABASE_URL = "postgres://vaultwarden?host=/run/postgresql";
      DISABLE_ADMIN_TOKEN = true;
      SIGNUPS_ALLOWED = false;
      INVITATIONS_ALLOWED = true;
      WEB_VAULT_ENABLED = true;
    };
  };
  systemd.services.vaultwarden = {
    path = [ pkgs.system-sendmail ];
    requires = [ "postgresql.service" ];
    after = [ "postgresql.service" ];
  };

  services.nginx.virtualHosts."${vaultwardenDomain}" = {
    forceSSL = true;
    useACMEHost = config.common.domain;
    locations."/" = {
      proxyPass = "http://127.0.0.1:${toString config.services.vaultwarden.config.ROCKET_PORT}";
    };
  };
}
