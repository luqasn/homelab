{
  config,
  lib,
  ...
}:
let
  cfg = config.mares.starr;
  utils = import ../../../lib {
    inherit config;
    inherit lib;
  };
in
{
  config = lib.mkIf (cfg.enable && cfg.sabnzbd.enable) {

    services.sabnzbd = {
      enable = true;
      group = cfg.group;
    };

    services.nginx.virtualHosts."sabnzbd.${config.common.internalDomain}" = utils.mkVirtualHost {
      port = 8080;
      internal = true;
    };

    systemd.services.sabnzbd = {
      wants = [
        "sops-nix.service"
      ];

      after = [
        "sops-nix.service"
      ];
    };
  };
}
