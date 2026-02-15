{
  lib,
  config,
  ...
}:
let
  utils = import ../../lib {
    inherit config;
    inherit lib;
  };
in
{
  imports = [
    ./mqtt.nix
    ./esphome.nix
  ];
  services.home-assistant = {
    enable = true;
    # opt-out from declarative configuration management
    config = {
      homeassistant = {
        customize = {
            "sensor.enbee_strom_total_in" = {
                      device_class = "energy";
                      state_class = "total_increasing";
                      unit_of_measurement = "kWh";
                    };
        };
      };
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
      assist_pipeline = { };
      backup = { };
      config = { };
      conversation = { };
      energy = { };
      history = { };
      homeassistant_alerts = { };
      logbook = { };
      mobile_app = { };
      sun = { };
      recorder = { };
      prometheus = {
        # Handled separately.
#        requires_auth = false;
      };
      "automation ui" = "!include automations.yaml";
      "scene ui" = "!include scenes.yaml";
      "script ui" = "!include scripts.yaml";
    };
    #    lovelaceConfig = null;
    # configure the path to your config directory
    # configDir = lib.mkDefault throw "Please set `configDir` for home assistant";
    # specify list of components required by your configuration
    extraComponents = [
      "default_config"
      "weather"
      "met"
      "zeroconf"
      "esphome"
      "fritz"
      "zha"
      "mqtt"
      "tasmota"
      "recorder"
      "mobile_app"
      "history"
      "history_stats"
      "logbook"
      "isal"
      "prometheus"
      # "met"
      # "radio_browser"
    ];
    extraPackages =
      ps: with ps; [
        numpy
        #              hatasmota
        pyturbojpeg
        #              paho-mqtt
        pynacl

        defusedxml
        gtts
        aiogithubapi
        radios
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
