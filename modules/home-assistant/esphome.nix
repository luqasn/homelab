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
    services.esphome = {
      enable = true;
    };
        # https://github.com/NixOS/nixpkgs/issues/339557
  systemd.services.esphome.serviceConfig = {
    ProtectSystem = lib.mkForce "off";
    DynamicUser = lib.mkForce "false";
    User = "esphome";
    Group = "esphome";
  };
  users.users.esphome = {
    isSystemUser = true;
    home = "/var/lib/esphome";
    group = "esphome";
  };
  users.groups.esphome = {};


  services.nginx.virtualHosts."esphome.${config.common.internalDomain}" = utils.mkVirtualHost {
    port = config.services.esphome.port;
    internal = true;
    settings = {
      proxyWebsockets = true;
    };
  };
}