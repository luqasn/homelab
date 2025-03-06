{
  config,
  lib,
  ...
}:
let
  utils = import ../lib {
    inherit config;
    inherit lib;
  };
in
{
  services.actual = {
    enable = true;
    settings = {
      port = 5006;
    };
  };

  services.nginx.virtualHosts."money.${config.common.internalDomain}" = utils.mkVirtualHost {
    port = config.services.actual.settings.port;
    internal = true;
  };
}
