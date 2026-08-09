{
  config,
  pkgs,
  inputs,
  lib,
  ...
}:
let
  immichDomain = "immich.${config.common.domain}";
  utils = import ../lib {
    inherit config;
    inherit lib;
  };
  pkgs-immich-kiosk = import inputs.nixpkgs-immich-kiosk {
    inherit system;
  };
in
{
  services.immich = {
    enable = true;
    port = 2283;
    accelerationDevices = null;

    settings = {
      server.externalDomain = "https://${immichDomain}";

      notifications.smtp = {
        enabled = true;
        from = config.programs.msmtp.accounts.default.from;
        replyTo = "";
        transport = {
          ignoreCert = false;
          host = config.programs.msmtp.accounts.default.host;
          port = config.programs.msmtp.defaults.port;
          secure = true;
          username = config.programs.msmtp.accounts.default.user;
          password._secret = config.sops.secrets.sendgrid-password.path;
        };
      };
    };
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
    package = pkgs-immich-kiosk.immich-kiosk;
    settings = {
      immich_url = "http://localhost:${toString config.services.immich.port}";
      immich_api_key._secret = config.sops.secrets.immich-api-key.path;
      immich_users_api_keys.marlena._secret = config.sops.secrets.immich-api-key-marlena.path;

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
        "favorites@marlena"
#        "2a7cacb8-fbea-47e1-adcc-7899ea2888e6"
      ];
      #      memories = true;
      layout = "splitview";
      show_owner = true;
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
