{
  config,
  pkgs,
  lib,
  ...
}:
let
  immichDomain = "immich.${config.common.domain}";
  utils = import ../lib {
    inherit config;
    inherit lib;
  };
in
{
  services.immich = {
    enable = true;
    port = 2283;
    accelerationDevices = null;
  };

  users.users.immich.extraGroups = [
    "video"
    "render"
  ];

  services.nginx.virtualHosts.${immichDomain} = {
    forceSSL = true;
    useACMEHost = config.common.domain;
    locations."/" = {
      proxyPass = "http://[::1]:${toString config.services.immich.port}";
      proxyWebsockets = true;
      recommendedProxySettings = true;
      extraConfig = ''
        client_max_body_size 50000M;
        proxy_read_timeout   600s;
        proxy_send_timeout   600s;
        send_timeout         600s;
      '';
    };
  };

  services.immich-kiosk = {
    enable = true;
    settings = {
      immich_url = "http://localhost:${toString config.services.immich.port}";
      immich_api_key._secret = config.sops.secrets.immich-api-key.path;

      kiosk = {
        port = 2284;
        behind_proxy = true;
      };
      duration = 45;
      show_time = false;
      show_date = false;
#      time_format = 24;
#      date_format = "DD.MM.YYYY";
#      clock_source = "client";
      #          people = [
      #          ];
      albums = [
        "favorites"
      ];
#      memories = true;
      layout = "splitview";
      show_image_date = true;
      image_date_format = "DD.MM.YYYY";
      show_image_location = true;
    };
  };

  services.nginx.virtualHosts."immich-kiosk.${config.common.internalDomain}" = utils.mkVirtualHost {
    port = config.services.immich-kiosk.settings.kiosk.port;
    internal = true;
  };
}
