{
  config,
  lib,
  pkgs,
  ...
}:
let
  utils = import ../lib {
    inherit config;
    inherit lib;
  };
  karakeepHttpPort = 8778;
in
{
  services.karakeep = {
    enable = true;
    meilisearch.enable = true;
    browser.enable = true;

    extraEnvironment = {
      "PORT" = toString karakeepHttpPort;
      "NEXTAUTH_URL" = "https://karakeep.${config.common.domain}";
      "DISABLE_SIGNUPS" = "true";
    };
  };

  services.nginx.virtualHosts."karakeep.${config.common.domain}" = utils.mkVirtualHost {
    port = karakeepHttpPort;
    internal = false;
  };
}
