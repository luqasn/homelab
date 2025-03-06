{ config, pkgs, ... }:
{
  services.jellyfin.enable = true;
  services.jellyfin.group = config.mares.starr.group;
  environment.systemPackages = [
    pkgs.jellyfin
    pkgs.jellyfin-web
    pkgs.jellyfin-ffmpeg
  ];

  #  services.nginx.virtualHosts."sam.lan" = {
  #   locations."/jellyfin" = {
  #    proxyPass = "http://127.0.0.1:8096";
  #    proxyWebsockets = true;
  #   };
  #  };

  services.nginx.virtualHosts."media.${config.common.domain}" = {
    forceSSL = true;
    useACMEHost = config.common.domain;

    locations."/" = {
      proxyPass = "http://localhost:8096";
      proxyWebsockets = true;
    };
  };
}
