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
  services.grafana = {
    enable = true;
    settings = {
      server = {
        domain = "grafana.${config.common.internalDomain}";
        port = 3000;
        #    http_addr = "127.0.0.1";
      };
    };
  };

  sops.secrets.homeassistant-access-token = {
    owner = "prometheus";
    group = "prometheus";
  };

  services.scrutiny = {
    enable = true;
    settings = {
      web.listen = {
        host = "127.0.0.1";
        port = 8081;
      };
    };
  };

  services.nginx.virtualHosts."scrutiny.${config.common.internalDomain}" = utils.mkVirtualHost {
    port = config.services.scrutiny.settings.web.listen.port;
    internal = true;
  };

  services.prometheus = {
    enable = true;
    port = 9001;
    exporters = lib.mkMerge [
      {
        node = {
          enable = true;
          enabledCollectors = [ "systemd" ];
          port = 9002;
        };
        systemd = {
          enable = true;
          listenAddress = "localhost";
        };
      }
      (lib.optionalAttrs (config.boot.supportedFilesystems.zfs or false) {
        zfs = {
          enable = true;
          listenAddress = "localhost";
        };
      })
      (lib.optionalAttrs config.services.smartd.enable {
        smartctl = {
          enable = true;
          listenAddress = "localhost";
          maxInterval = "5m";
        };
      })
    ];

    checkConfig = "syntax-only";

    rules = [
      (builtins.toJSON {
        groups = [
          {
            name = "rules";
            rules = [
              {
                alert = "systemd unit failed";
                expr = ''
                  node_systemd_unit_state{state="failed"} > 0
                '';
                for = "5m";
                annotations = {
                  summary = "Unit {{ $labels.name }} failed";
                };
              }
            ];
          }
        ];
      })
    ];

    scrapeConfigs =
      [
        {
          job_name = "node";
          static_configs = [
            {
              targets = [ "127.0.0.1:${toString config.services.prometheus.exporters.node.port}" ];
            }
          ];
        }
        {
          job_name = "systemd";
          static_configs = [
            {
              targets = [ "127.0.0.1:${toString config.services.prometheus.exporters.systemd.port}" ];
            }
          ];
        }
        {
          job_name = "homeassistant";
          metrics_path = "/api/prometheus";
          bearer_token_file = config.sops.secrets.homeassistant-access-token.path;
          static_configs = [
            {
              targets = [ "192.168.1.5:8123" ];
            }
          ];
        }
        {
          job_name = "offsite_server_power";
          static_configs = [
            {
              targets = [ "192.168.178.7" ];
            }
          ];
        }
      ]
      ++ lib.optionals config.services.prometheus.exporters.zfs.enable [
        {
          job_name = "zfs";
          static_configs = [
            { targets = [ "localhost:${toString config.services.prometheus.exporters.zfs.port}" ]; }
          ];
        }
      ]
      ++ lib.optionals config.services.prometheus.exporters.smartctl.enable [
        {
          job_name = "smartctl";
          static_configs = [
            { targets = [ "localhost:${toString config.services.prometheus.exporters.smartctl.port}" ]; }
          ];
        }
      ];
  };

  services.nginx.virtualHosts."prometheus.${config.common.internalDomain}" = utils.mkVirtualHost {
    port = config.services.prometheus.port;
    internal = true;
  };

  services.nginx.virtualHosts."grafana.${config.common.internalDomain}" = utils.mkVirtualHost {
    port = config.services.grafana.settings.server.port;
    internal = true;
    settings = {
      proxyWebsockets = true;
    };
  };
}
