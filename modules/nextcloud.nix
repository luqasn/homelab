{
  config,
  pkgs,
  lib,
  ...
}:
let
  collaboraDomain = "docs.${config.common.domain}";
  nextcloudDomain = "nextcloud.${config.common.domain}";
  occ = "${config.services.nextcloud.occ}/bin/nextcloud-occ";
  exifToolMemories = pkgs.exiftool.overrideAttrs (oldAttrs: rec {
    version = "12.70";
    src = pkgs.fetchurl {
      url = "https://exiftool.org/Image-ExifTool-12.70.tar.gz";
      hash = "sha256-TLJSJEXMPj870TkExq6uraX8Wl4kmNerrSlX3LQsr/4=";
    };
  });
in
{
  options = {
    datasets.nextcloud = lib.mkOption {
      type = lib.types.str;
    };
  };
  config = {

    networking.extraHosts = ''
      127.0.0.1 ${collaboraDomain}
    '';

    users.groups.sendmail.members = [
      "nextcloud"
    ];

    clan.core.vars.generators.nextcloud = {
      files.admin_password = {
        owner = "nextcloud";
      };
      runtimeInputs = [
        pkgs.coreutils
        pkgs.openssl
      ];
      script = ''
        openssl rand -base64 -out "$out/admin_password" 32
      '';
    };

    environment.systemPackages = with pkgs; [
      ffmpeg-headless # required for Memories
      ghostscript
    ];

    systemd.services.nextcloud-cron = {
      # required for memories
      # see https://github.com/pulsejet/memories/blob/master/docs/troubleshooting.md#issues-with-nixos
      path = [ pkgs.perl ];
    };
    services.nextcloud = {
      # See all options at https://memories.gallery/system-config/
      settings = {
        "memories.exiftool" = lib.getExe exifToolMemories;
        "memories.exiftool_no_local" = false;
        # "memories.index.mode" = "3";
        # "memories.index.path" = cfg'.photosPath;
        # "memories.timeline.default_path" = cfg'.photosPath;

        "memories.vod.disable" = false;
        "memories.vod.vaapi" = true;
        "memories.vod.ffmpeg" = lib.getExe pkgs.ffmpeg-headless;
        "memories.vod.ffprobe" = "${pkgs.ffmpeg-headless}/bin/ffprobe";
        "memories.vod.use_transpose" = true;
        "memories.vod.use_transpose.force_sw" = true; # AMD and old Intel can't use hardware here.

        "memories.db.triggers.fcu" = true;
        "memories.readonly" = false;
        "preview_ffmpeg_path" = lib.getExe pkgs.ffmpeg-headless;
      };
    };

    systemd.services.phpfpm-nextcloud.serviceConfig = {
      DeviceAllow = [ "/dev/dri/renderD128 rwm" ];
      PrivateDevices = lib.mkForce false;
    };

    services.nextcloud = {
      enable = true;
      https = true;
      hostName = nextcloudDomain;

      #    serviceConfig = {
      #      ConditionPathIsMountPoint = [config.datasets.nextcloud];
      #    };
      datadir = config.datasets.nextcloud;

      # Need to manually increment with every major upgrade.
      package = pkgs.nextcloud31;

      database.createLocally = false;

      # Let NixOS install and configure Redis caching automatically.
      configureRedis = true;

      # Increase the maximum file upload size to avoid problems uploading videos.
      maxUploadSize = "16G";

      settings = {
        "overwrite.cli.url" = "https://${nextcloudDomain}";
        "maintenance_window_start" = 1;
        default_phone_region = "DE";
        trusted_proxies = [ "127.0.0.1" ];
        trusted_domains = [ nextcloudDomain ];
        overwriteprotocol = "https"; # Needed if behind a reverse_proxy
        overwritecondaddr = ""; # We need to set it to empty otherwise overwriteprotocol does not work.
        mail_smtpmode = "sendmail";
        mail_sendmailmode = "pipe";
        mail_domain = "romeromail.de";
        mail_from_address = "server";
        # log_type = "file";
        #loglevel = 0;
        # Use persistent SQL connections.
        dbpersistent = "true";

        # https://help.nextcloud.com/t/very-slow-sync-for-small-files/11064/13
        chunkSize = "5120MB";

        # migration
        installed = true;
      };

      secretFile = config.sops.secrets.nextcloud-secrets-json.path;

      config = {
        dbtype = "pgsql";
        dbuser = "oc_nextcloud";
        dbname = "oc_nextcloud";
        dbhost = "/run/postgresql";
        adminuser = "admin";
        adminpassFile = config.clan.core.vars.generators.nextcloud.files.admin_password.path;
      };
      extraApps = {
        inherit (config.services.nextcloud.package.packages.apps)
          # mail
          calendar
          cospend
          contacts
          richdocuments
          previewgenerator
          notify_push
          tasks
          recognize
          ;
        memories = pkgs.fetchNextcloudApp {
          sha256 = "sha256-BfxJDCGsiRJrZWkNJSQF3rSFm/G3zzQn7C6DCETSzw4=";
          url = "https://github.com/pulsejet/memories/releases/download/v7.5.2/memories.tar.gz";
          license = "agpl3Only";
        };
      };
      extraAppsEnable = true;
      phpOptions = {
        # The OPcache interned strings buffer is nearly full with 8, bump to 16.
        catch_workers_output = "yes";
        display_errors = "stderr";
        error_reporting = "E_ALL & ~E_DEPRECATED & ~E_STRICT";
        expose_php = "Off";
        "opcache.enable_cli" = "1";
        "opcache.fast_shutdown" = "1";
        "opcache.interned_strings_buffer" = "16";
        "opcache.max_accelerated_files" = "10000";
        "opcache.memory_consumption" = "128";
        "opcache.revalidate_freq" = "1";
        short_open_tag = "Off";

        # https://docs.nextcloud.com/server/stable/admin_manual/configuration_files/big_file_upload_configuration.html#configuring-php
        # > Output Buffering must be turned off [...] or PHP will return memory-related errors.
        output_buffering = "Off";

        # Needed to avoid corruption per https://docs.nextcloud.com/server/21/admin_manual/configuration_server/caching_configuration.html#id2
        "redis.session.locking_enabled" = "1";
        "redis.session.lock_retries" = "-1";
        "redis.session.lock_wait_time" = "10000";
      };

      settings.enabledPreviewProviders = [
        "OC\\Preview\\BMP"
        "OC\\Preview\\GIF"
        "OC\\Preview\\JPEG"
        "OC\\Preview\\Krita"
        "OC\\Preview\\MarkDown"
        "OC\\Preview\\MP3"
        "OC\\Preview\\OpenDocument"
        "OC\\Preview\\PNG"
        "OC\\Preview\\TXT"
        "OC\\Preview\\XBitmap"
        "OC\\Preview\\HEIC"
        "OC\\Preview\\PDF"
        "OC\\Preview\\Movie"
      ];
    };

    sops.secrets.nextcloud-secrets-json = {
      owner = "nextcloud";
      group = "nextcloud";
    };

    systemd.services.nextcloud-setup = {
      script = ''
        ${occ} config:app:set previewgenerator squareSizes --value="32 256"
        ${occ} config:app:set previewgenerator widthSizes  --value="256 384"
        ${occ} config:app:set previewgenerator heightSizes --value="256"
        ${occ} config:system:set preview_max_x --value 1024
        ${occ} config:system:set preview_max_y --value 1024
        ${occ} config:system:set jpeg_quality --value 60
        ${occ} config:app:set preview jpeg_quality --value="60"

        ${occ} config:app:set recognize nice_binary --value ${pkgs.coreutils}/bin/nice
        ${occ} config:app:set recognize node_binary --value ${pkgs.nodejs}/bin/node
        ${occ} config:app:set recognize faces.enabled --value true
        ${occ} config:app:set recognize faces.batchSize --value 50
        ${occ} config:app:set recognize imagenet.enabled --value true
        ${occ} config:app:set recognize imagenet.batchSize --value 100
        ${occ} config:app:set recognize landmarks.batchSize --value 100
        ${occ} config:app:set recognize landmarks.enabled --value true
        ${occ} config:app:set recognize tensorflow.cores --value 1
        ${occ} config:app:set recognize tensorflow.gpu --value false
        ${occ} config:app:set recognize tensorflow.purejs --value false
        ${occ} config:app:set recognize musicnn.enabled --value false
        ${occ} config:app:set recognize musicnn.batchSize --value 100
      '';
      requires = [ "postgresql.service" ];
      after = [ "postgresql.service" ];
    };

    # Configured as defined in https://github.com/nextcloud/previewgenerator
    systemd.timers.nextcloud-cron-previewgenerator = {
      wantedBy = [ "timers.target" ];
      after = [ "nextcloud-setup.service" ];
      timerConfig.OnBootSec = "10m";
      timerConfig.OnUnitActiveSec = "10m";
      timerConfig.Unit = "nextcloud-cron-previewgenerator.service";
    };

    systemd.services.nextcloud-cron-previewgenerator = {
      environment.NEXTCLOUD_CONFIG_DIR = "${config.services.nextcloud.datadir}/config";
      serviceConfig.Type = "oneshot";
      serviceConfig.User = "nextcloud";
      serviceConfig.ExecStart = "${occ} preview:pre-generate";
    };

    virtualisation.podman.enable = true;
    virtualisation.oci-containers.containers."collabora" = {
      autoStart = true;
      image = "docker.io/collabora/code:latest";
      ports = [ "9980:9980/tcp" ];
      environment = {
        server_name = collaboraDomain;
        dictionaries = "en_US";
        extra_params = "--o:ssl.enable=false --o:ssl.termination=true";
        # extra_params = "--o:ssl.enable=false";
      };
      extraOptions = [
        "--cap-add"
        "MKNOD"
      ];
    };

    services.nginx.virtualHosts.${config.services.nextcloud.hostName} = {
      forceSSL = true;
      useACMEHost = config.common.domain;
      # From [1] this should fix downloading of big files. [2] seems to indicate that buffering
      # happens at multiple places anyway, so disabling one place should be okay.
      # [1]: https://help.nextcloud.com/t/download-aborts-after-time-or-large-file/25044/6
      # [2]: https://stackoverflow.com/a/50891625/1013628
      extraConfig = ''
        proxy_buffering off;
      '';
    };

    services.nginx.virtualHosts.${collaboraDomain} = {
      forceSSL = true;
      useACMEHost = config.common.domain;
      extraConfig = ''
         # static files
         location ^~ /browser {
           proxy_pass http://127.0.0.1:9980;
           proxy_set_header Host $host;
         }

         # WOPI discovery URL
         location ^~ /hosting/discovery {
           proxy_pass http://127.0.0.1:9980;
           proxy_set_header Host $host;
         }

         # Capabilities
         location ^~ /hosting/capabilities {
           proxy_pass http://127.0.0.1:9980;
           proxy_set_header Host $host;
        }

        # main websocket
        location ~ ^/cool/(.*)/ws$ {
          proxy_pass http://127.0.0.1:9980;
          proxy_set_header Upgrade $http_upgrade;
          proxy_set_header Connection "Upgrade";
          proxy_set_header Host $host;
          proxy_read_timeout 36000s;
        }

        # download, presentation and image upload
        location ~ ^/(c|l)ool {
          proxy_pass http://127.0.0.1:9980;
          proxy_set_header Host $host;
        }

        # Admin Console websocket
        location ^~ /cool/adminws {
          proxy_pass http://127.0.0.1:9980;
          proxy_set_header Upgrade $http_upgrade;
          proxy_set_header Connection "Upgrade";
          proxy_set_header Host $host;
          proxy_read_timeout 36000s;
        }
      '';
    };
  };
}
