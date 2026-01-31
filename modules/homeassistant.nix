{
  lib,
  config,
  ...
}:
let
  utils = import ../lib {
    inherit config;
    inherit lib;
  };
in
{
  services.home-assistant = {
    enable = true;
    # opt-out from declarative configuration management
    config = {
          http = {
            server_host = [
              "127.0.0.1"
            ];
            server_port = 8123;
            use_x_forwarded_for = true;
            trusted_proxies = [
              "127.0.0.1"
            ];
          };
    };
#    lovelaceConfig = null;
    # configure the path to your config directory
    # configDir = lib.mkDefault throw "Please set `configDir` for home assistant";
    # specify list of components required by your configuration
    extraComponents = [
      "esphome"
      "zha"
              "mqtt"
              "tasmota"
      # "met"
      # "radio_browser"
    ];
            extraPackages = ps: with ps;
              [
              numpy
#              hatasmota
              pyturbojpeg
#              paho-mqtt
              pynacl

              defusedxml
              ];
  };

  services.nginx.virtualHosts."homeassistant.${config.common.internalDomain}" = utils.mkVirtualHost {
    port = config.services.home-assistant.config.http.server_port;
    internal = true;
    settings = {
      proxyWebsockets = true;
    };
  };
}
