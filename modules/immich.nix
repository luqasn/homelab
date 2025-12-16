{ config, pkgs, ... }:
let
  immichDomain = "immich.${config.common.domain}";
in
{
    services.immich = {
        enable = true;
        port = 2283;
        accelerationDevices = null;
    };

    users.users.immich.extraGroups = [ "video" "render" ];

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
}