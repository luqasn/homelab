{
  config,
  pkgs,
  lib,
  ...
}:
let
  vaultwardenDomain = "vault.${config.common.domain}";
  emailFrom = "server@romeromail.de";
  emailTo = "lucas@romeromail.de"; # where to send the notifications
in
{
  options = {
    common.domain = lib.mkOption {
      type = lib.types.str;
    };
    common.internalDomain = lib.mkOption {
      type = lib.types.str;
      default = "internal.${config.common.domain}";
    };
    common.internalIp = lib.mkOption {
      type = lib.types.str;
    };
    datasets.postgres = lib.mkOption {
      type = lib.types.str;
    };
  };
  config = {
    nixpkgs.config.packageOverrides = pkgs: {
      zfsStable = pkgs.zfsStable.override { enableMail = true; };
    };
    environment.systemPackages = with pkgs; [
      curl
      mailutils
      neovim
      pciutils
      screen
      iotop
      zfs-autobackup
    ];
    services.zfs = {
      zed = {
        enableMail = true;
        settings = {
          ZED_EMAIL_ADDR = [ emailTo ];
          ZED_EMAIL_OPTS = "-a 'FROM:${emailFrom}' -s '@SUBJECT@' @ADDRESS@";
          ZED_NOTIFY_VERBOSE = true;
        };
      };
    };

    services.smartd = {
      enable = true;
      notifications.mail = {
        enable = true;
        sender = emailFrom;
        recipient = emailTo;
      };
    };

    services.openssh = {
      enable = true;
      # require public key authentication for better security
      settings.PasswordAuthentication = false;
      settings.KbdInteractiveAuthentication = false;
    };
    networking.firewall = {
      enable = false;
      allowedTCPPorts = [
        80
        22
        443
        444
        #      9090
      ];
    };
    clan.core.vars.generators.postgres = {
      files.postgres_password = {
        owner = "postgres";
      };
      runtimeInputs = [
        pkgs.coreutils
        pkgs.openssl
      ];
      script = ''
        openssl rand -base64 -out "$out/postgres_password" 32
      '';
    };

    systemd.services.postgresql.postStart =
      let
        password_file_path = config.clan.core.vars.generators.postgres.files.postgres_password.path;
      in
      ''
        $PSQL -tA <<'EOF'
          DO $$
          DECLARE password TEXT;
          BEGIN
            password := trim(both from replace(pg_read_file('${password_file_path}'), E'\n', '''));
            EXECUTE format('ALTER ROLE postgres WITH PASSWORD '''%s''';', password);
          END $$;
        EOF
      '';

    systemd.services.postgresql.serviceConfig.ConditionPathIsMountPoint = [
      config.datasets.postgres
    ];

    services.postgresql = {
      enable = true;
      dataDir = config.datasets.postgres;
      ensureDatabases = [
        "nextcloud"
        "oc_nextcloud"
        "vaultwarden"
      ];
      ensureUsers = [
        {
          name = "nextcloud";
          ensureDBOwnership = true;
        }
        {
          name = "oc_nextcloud";
          ensureDBOwnership = true;
        }
        {
          name = "vaultwarden";
          ensureDBOwnership = true;
        }
      ];
      identMap = ''
        # ArbitraryMapName systemUser DBUser
        superuser_map      root  postgres
        superuser_map      postgres  postgres
        superuser_map      nextcloud  oc_nextcloud
        # Let other names login as themselves
        superuser_map      /^(.*)$   \1
      '';
      authentication = pkgs.lib.mkOverride 10 ''
        #type database  DBuser  auth-method optional_ident_map
        local sameuser  all     peer        map=superuser_map
        local all  postgres     peer        map=superuser_map
        #local nextcloud oc_nextcloud peer   map=superuser_map
        #type database DBuser origin-address auth-method
        # ipv4
        host  all      all     127.0.0.1/32   scram-sha-256
        # ipv6
        host all       all     ::1/128        scram-sha-256
      '';
    };

    sops.secrets.sendgrid-password = {
      group = "sendmail";
      mode = "0440";
    };

    users.groups.sendmail.members = [
      #      "vaultwarden"
      "root"
    ];

    programs.msmtp = {
      enable = true;
      setSendmail = true;
      defaults = {
        aliases = builtins.toFile "aliases" ''
          default: ${emailTo}
        '';
        port = 465;
        tls_trust_file = "/etc/ssl/certs/ca-certificates.crt";
        tls = "on";
        auth = "login";
        tls_starttls = "off";
      };
      accounts = {
        default = {
          host = "smtp.sendgrid.net";
          passwordeval = "cat ${config.sops.secrets.sendgrid-password.path}";
          user = "apikey";
          from = emailFrom;
        };
      };
    };

    #    nixpkgs.config.allowUnfree = true;
    #
    #    # Set-up media group
    #    users.groups.media = { };
    #
    #    services.sabnzbd = {
    #      enable = true;
    #      group = "media";
    #    };
    #
    #    services.nginx.virtualHosts."sabnzbd.${config.common.domain}" = {
    #      forceSSL = true;
    #      useACMEHost = config.common.domain;
    #
    #      locations."/".proxyPass = "http://localhost:8080";
    #    };

    #
    # systemd.services.nextcloud = {
    #   path = [ pkgs.system-sendmail ];
    #   requires = [ "postgresql.service" ];
    #   after = [ "postgresql.service" ];
    # };

    # Values taken from
    # http://web.archive.org/web/20200513043150/https://ownyourbits.com/2019/06/29/understanding-and-improving-nextcloud-previews/

    security.acme = {
      acceptTerms = true;
      defaults = {
        email = "lucas@romeromail.de";
        # server = "https://acme-staging-v02.api.letsencrypt.org/directory";
      };
      certs = {
        "${config.common.domain}" = {
          group = config.services.nginx.group;
          extraDomainNames = [
            "*.${config.common.domain}"
            "*.${config.common.internalDomain}"
          ];
          dnsProvider = "cloudflare";
          dnsResolver = "1.1.1.1:53";
          dnsPropagationCheck = true;
          credentialFiles = {
            "CLOUDFLARE_EMAIL_FILE" = config.sops.secrets.cloudflare-email.path;
            "CLOUDFLARE_DNS_API_TOKEN_FILE" = config.sops.secrets.cloudflare-dns-token.path;
          };
        };
      };
    };

    # virtualisation.oci-containers = {
    #   backend = "docker";
    # };
    # Online document editing

    services.nginx = {
      enable = true;
      recommendedGzipSettings = true;
      recommendedProxySettings = true;
      recommendedOptimisation = true;
      recommendedTlsSettings = true;
    };

  };
}
