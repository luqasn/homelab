{
  config,
  lib,
  mares,
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
  config = lib.mkIf (cfg.enable && cfg.sonarr.enable) {
    sops.templates."sonarr-config.xml" = {
      content =
        helpers.toXML
          {
            rootName = "Config";
            xmlns = { };
          }
          {
            BindAddress = "${cfg.sonarr.bindAddress}";
            Port = 8989;
            SslPort = 9898;
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
            InstanceName = "Sonarr";
            AnalyticsEnabled = false;
            DownloadPropersAndRepacks = "DoNotPrefer";
            #            PostgresUser = "sonarr";
            #            PostgresPassword = "${config.sops.placeholder.pgsql-sonarr_password}";
            #            PostgresPort = "${toString cfg.postgres.port}";
            #            PostgresHost = "${cfg.postgres.host}";
            #            PostgresMainDb = "sonarr";
            #            PostgresLogDb = "sonarr_log";
          };

      path = "${config.services.sonarr.dataDir}/config.xml";
      owner = cfg.sonarr.user;
      group = cfg.group;
      mode = "0660";

      restartUnits = [ "sonarr.service" ];
    };

    services.sonarr = {
      enable = true;
      dataDir = "${cfg.pathPrefix}/sonarr";
      group = cfg.group;
    };

    services.nginx.virtualHosts."sonarr.${config.common.internalDomain}" = utils.mkVirtualHost {
      port = 8989;
      internal = true;
    };

    systemd.services.sonarr = {
      wants = [
        "sops-nix.service"
      ];
      after = [
        "sops-nix.service"
      ];
    };
  };
}
