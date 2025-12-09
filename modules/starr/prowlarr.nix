{
  config,
  lib,
  ...
}:
let
  cfg = config.mares.starr;
  utils = import ../../lib {
    inherit config;
    inherit lib;
  };
  helpers = import ./lib {
    inherit lib;
  };
in
{
  config = lib.mkIf (cfg.enable && cfg.prowlarr.enable) {
    sops.templates."prowlarr-config.xml" = {
      content =
        helpers.toXML
          {
            rootName = "Config";
            xmlns = { };
          }
          {
            BindAddress = "127.0.0.1";
            Port = 9696;
            SslPort = 6969;
            EnableSsl = false;
            LaunchBrowser = false;
            ApiKey = config.sops.placeholder.arr-apikey;
            AuthenticationMethod = "Forms";
            #            AuthenticationRequired = "Enabled";
            AuthenticationRequired = "DisabledForLocalAddresses";
            Branch = "master";
            LogLevel = "debug";
            SslCertPath = "";
            SslCertPassword = "";
            UrlBase = "";
            InstanceName = "Prowlarr";
            AnalyticsEnabled = false;
            #            PostgresUser = "prowlarr";
            #            PostgresPassword = config.sops.placeholder.pgsql-prowlarr_password;
            #            PostgresPort = "${toString cfg.postgres.port}";
            #            PostgresHost = "${cfg.postgres.host}";
            #            PostgresMainDb = "prowlarr";
            #            PostgresLogDb = "prowlarr_log";
          };

      path = "${config.users.users.prowlarr.home}/config.xml";
      owner = cfg.prowlarr.user;
      group = cfg.group;
      mode = "0660";

      restartUnits = [ "prowlarr.service" ];
    };

    services.prowlarr = {
      enable = true;
    };

    # fix bug
    systemd.tmpfiles.settings."10-prowlarr" = lib.mkForce {};

    services.nginx.virtualHosts."prowlarr.${config.common.internalDomain}" = utils.mkVirtualHost {
      port = 9696;
      internal = true;
    };

    fileSystems."/var/lib/prowlarr" = lib.mkIf (cfg.pathPrefix != "/var/lib") {
      depends = [
          cfg.pathPrefix
      ];
      device = "${cfg.pathPrefix}/prowlarr";
      fsType = "none";
      options = [
        "bind"
      ];
    };

    systemd.services.prowlarr = {
      serviceConfig = {
        DynamicUser = lib.mkForce false;
        User = lib.mkDefault cfg.prowlarr.user;
        Group = lib.mkDefault cfg.group;
      };

      wants = [
        "sops-nix.service"
      ];

      after = [
        "sops-nix.service"
      ];
    };
  };
}
