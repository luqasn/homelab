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

  # Nextcloud talks to Collabora over loopback; the browser uses the public
  # HTTPS URL. See https://diogotc.com/blog/collabora-nextcloud-nixos/.
  collaboraWopiUrl = "http://[::1]:${toString config.services.collabora-online.port}";
  collaboraPublicWopiUrl = "https://${collaboraDomain}";
  # Collabora connects to Nextcloud from loopback (see the networking.hosts
  # workaround below), so only accept WOPI requests from there.
  wopiAllowlist = lib.concatStringsSep "," [
    "127.0.0.1"
    "::1"
  ];
in
{
  options = {
    datasets.nextcloud = lib.mkOption {
      type = lib.types.str;
    };
  };
  config = {
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

    systemd.timers."nextcloud-cron" = {
      #      wantedBy = [ "timers.target" ];
      timerConfig = lib.mkForce {
        # Run only from 08:00 to 22:00, every 30 minutes
        OnCalendar = "09..22:00/30";
        Unit = "nextcloud-cron.service";
        #        Persistent = true;
      };
    };

    systemd.services.nextcloud-cron = {
      # required for memories
      # see https://github.com/pulsejet/memories/blob/master/docs/troubleshooting.md#issues-with-nixos
      path = [ pkgs.perl ];
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
      package = pkgs.nextcloud33;

      database.createLocally = false;

      # Let NixOS install and configure Redis caching automatically.
      configureRedis = true;

      # Increase the maximum file upload size to avoid problems uploading videos.
      maxUploadSize = "16G";

      settings = {
        "preview_ffmpeg_path" = lib.getExe pkgs.ffmpeg-headless;

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
        cache_path = "${config.datasets.nextcloud}/cache";

        appstoreenabled = true;
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
          ;
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

    # richdocuments (Nextcloud Office) keeps its Collabora settings in the
    # database, so they have to be applied with `occ` after Nextcloud and
    # Collabora are both up. Running as `nextcloud` plus LoadCredential avoids
    # the occ wrapper's systemd-run fallback (it needs a credentials directory
    # to exec PHP directly); the same pattern is used for the preview generator
    # below.
    systemd.services.nextcloud-config-collabora = {
      wantedBy = [ "multi-user.target" ];
      after = [
        "nextcloud-setup.service"
        "coolwsd.service"
      ];
      requires = [ "coolwsd.service" ];
      serviceConfig = {
        Type = "oneshot";
        User = "nextcloud";
        LoadCredential =
          "secret_file:${config.sops.secrets.nextcloud-secrets-json.path}";
      };
      script = ''
        ${occ} config:app:set richdocuments wopi_url --value ${lib.escapeShellArg collaboraWopiUrl}
        ${occ} config:app:set richdocuments public_wopi_url --value ${lib.escapeShellArg collaboraPublicWopiUrl}
        ${occ} config:app:set richdocuments wopi_allowlist --value ${lib.escapeShellArg wopiAllowlist}
        ${occ} richdocuments:setup
      '';
    };

    # Configured as defined in https://github.com/nextcloud/previewgenerator
    systemd.timers.nextcloud-cron-previewgenerator = {
      wantedBy = [ "timers.target" ];
      after = [ "nextcloud-setup.service" ];
      timerConfig.OnBootSec = "10m";
      timerConfig.OnUnitActiveSec = "10m";
      timerConfig.Unit = "nextcloud-cron-previewgenerator.service";
    };

    # NOTE on serviceConfig.LoadCredential: the NixOS `nextcloud-occ` wrapper
    # shells out to `systemd-run` to load runtime credentials whenever
    # CREDENTIALS_DIRECTORY is unset. That works when invoked by root, but this
    # unit runs as `nextcloud`, so `systemd-run` fails with "Access denied as
    # the requested operation requires interactive authentication". Loading
    # the same credential the wrapper wants (`secret_file`, i.e.
    # services.nextcloud.secretFile) here makes systemd provide
    # CREDENTIALS_DIRECTORY, so the wrapper execs php directly.
    systemd.services.nextcloud-cron-previewgenerator = {
      after = [ "nextcloud-setup.service" ];
      environment.NEXTCLOUD_CONFIG_DIR = "${config.services.nextcloud.datadir}/config";
      serviceConfig.Type = "oneshot";
      serviceConfig.User = "nextcloud";
      serviceConfig.ExecStart = "${occ} preview:pre-generate";
      serviceConfig.LoadCredential =
        "secret_file:${config.sops.secrets.nextcloud-secrets-json.path}";
    };

    services.collabora-online = {
      enable = true;

      settings = {
        # TLS is terminated by the nginx reverse proxy in front of Collabora.
        ssl = {
          enable = false;
          termination = true;
        };

        # Only the reverse proxy and Nextcloud (both local) talk to coolwsd.
        net = {
          listen = "loopback";
          post_allow.host = [ "::1" ];
        };

        # Only allow WOPI requests for our Nextcloud instance. Use
        # alias_groups rather than storage.wopi.host: the stock coolwsd.xml
        # always contains an alias_groups stanza, and Collabora ignores
        # storage.wopi.host when that stanza is present.
        storage.wopi = {
          "@allow" = true;
          alias_groups = {
            "@mode" = "groups";
            group = {
              host = {
                "@allow" = true;
                "+content" = "https://${nextcloudDomain}";
              };
            };
          };
        };

        # Public FQDN Collabora uses when generating URLs for the browser.
        server_name = collaboraDomain;

        # Not needed for the Nextcloud integration.
        admin_console.enable = false;

        # Hash document names/usernames in logs instead of writing them in
        # clear text. 6970438717373642851 is a random 63-bit salt.
        logging.anonymize = {
          anonymize_user_data = true;
          anonymization_salt = 6970438717373642851;
        };

        # These are the defaults; pin them so a package change cannot silently
        # enable document macros or the WebSocket URP endpoint.
        security = {
          enable_macros_execution = false;
          enable_websocket_urp = false;
        };
      };
    };

    # The NixOS module mirrors upstream's service except for sandboxing, which
    # upstream's coolwsd.service sets itself. Keep the same protections here;
    # coolwsd only needs to write its state directory.
    systemd.services.coolwsd.serviceConfig = {
      ProtectSystem = "strict";
      ReadWritePaths = [ "/var/lib/cool" ];
      ProtectHome = true;
      PrivateTmp = true;
      ProtectControlGroups = true;
      NoNewPrivileges = true;
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
      # One location is enough: Collabora serves /browser, /hosting/* and
      # /cool/* from the same backend. recommendedProxySettings (modules/
      # homelab.nix) sets the Host and X-Forwarded-* headers.
      locations."/" = {
        proxyPass = "http://[::1]:${toString config.services.collabora-online.port}";
        proxyWebsockets = true; # collabora uses websockets
        extraConfig = ''
          proxy_read_timeout 36000s;
          proxy_send_timeout 36000s;
        '';
      };
    };

    # Collabora has to fetch documents from Nextcloud. This host is behind NAT
    # with a dynamic public IP, so resolve Nextcloud (and Collabora) to
    # loopback locally. That keeps WOPI traffic on the machine and lets
    # wopi_allowlist stay loopback-only; see the linked blog post.
    networking.hosts = {
      "127.0.0.1" = [
        nextcloudDomain
        collaboraDomain
      ];
      "::1" = [
        nextcloudDomain
        collaboraDomain
      ];
    };
  };
}
