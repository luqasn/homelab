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
        GUNICORN_MEDIA = "1";
        ALLOWED_HOSTS = "recipes.${config.common.internalDomain}";
        TZ = "Europe/Berlin";
      };
    };
  services.nginx.virtualHosts."recipes.${config.common.internalDomain}" = utils.mkVirtualHost {
    port = tandoorHttpPort;
    internal = true;
  };
}