{
  config,
  lib,
  mares,
  ...
}:
with lib;
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
  config = lib.mkIf (cfg.enable && cfg.radarr.enable) {
    sops.templates."radarr-config.xml" = {
      content =
        helpers.toXML
          {
            rootName = "Config";
            xmlns = { };
          }
          {
            BindAddress = "127.0.0.1";
            Port = 7878;
            SslPort = 9898;
            EnableSsl = false;
            LaunchBrowser = false;
            ApiKey = config.sops.placeholder.arr-apikey;
            AuthenticationMethod = "Forms";
            AuthenticationRequired = "DisabledForLocalAddresses";
            Branch = "master";
            LogLevel = "debug";
            SslCertPath = "";
            SslCertPassword = "";
            UrlBase = "";
            InstanceName = "Radarr";
            AnalyticsEnabled = false;
            DownloadPropersAndRepacks = "DoNotPrefer";
            #            PostgresUser = "radarr";
            #            PostgresPassword = "${config.sops.placeholder.pgsql-radarr_password}";
            #            PostgresPort = "${toString cfg.postgres.port}";
            #            PostgresHost = "${cfg.postgres.host}";
            #            PostgresMainDb = "radarr";
            #            PostgresLogDb = "radarr_log";
          };

      path = "${config.services.radarr.dataDir}/config.xml";
      owner = cfg.radarr.user;
      group = cfg.group;
      mode = "0660";

      restartUnits = [ "radarr.service" ];
    };

    services.radarr = {
      enable = true;
      dataDir = "${cfg.pathPrefix}/radarr";
      group = cfg.group;
    };

    services.nginx.virtualHosts."radarr.${config.common.internalDomain}" = utils.mkVirtualHost {
      port = 7878;
      internal = true;
    };

    systemd.services.radarr = {
      wants = [
        "sops-nix.service"
      ];
      after = [
        "sops-nix.service"
      ];
    };
  };
}
