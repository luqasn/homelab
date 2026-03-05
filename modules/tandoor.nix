{
  pkgs,
  lib,
  config,
  self,
  ...
}:
let
  utils = import ../lib {
    inherit config;
    inherit lib;
  };
  tandoorHttpPort = 9768;
in
{
    services.tandoor-recipes = {
      enable = true;
      database.createLocally = true;
      port = tandoorHttpPort;

      extraConfig = {
        SECRET_KEY_FILE = config.sops.secrets.tandoor-secret.path;
        TZ = "Europe/Berlin";
      };
    };
  services.nginx.virtualHosts."recipes.${config.common.domain}" = utils.mkVirtualHost {
    port = tandoorHttpPort;
    internal = false;
  };
}