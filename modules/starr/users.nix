{
  config,
  lib,
  ...
}:
let
  cfg = config.mares.starr;
  enableArrs =
    cfg.prowlarr.enable
    || cfg.radarr.enable
    || cfg.sabnzbd.enable
    || cfg.sonarr.enable
    || cfg.recyclarr.enable
    || cfg.jellyfin.enable
    || cfg.jellyseerr.enable;
in
{
  config =

    lib.mkIf (cfg.enable && enableArrs) {
      users.groups.starr = {
        #        gid = config.ids.gids.starr;
        members = lib.mkIf config.services.nextcloud.enable [
          "nextcloud"
        ];
      };

      users.users = {
        prowlarr = lib.mkIf cfg.prowlarr.enable {
          home = "${cfg.pathPrefix}/prowlarr";
          isSystemUser = true;
          #          uid = config.ids.uids.prowlarr;
          group = "starr";
        };

        jellyseerr = lib.mkIf cfg.jellyseerr.enable {
          home = "${cfg.pathPrefix}/jellyseerr";
          #          uid = config.ids.uids.jellyseerr;
          group = "starr";
        };
      };
    };
}
