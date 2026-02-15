{
  config,
  lib,
  pkgs,
  ...
}:
let
  utils = import ../lib {
    inherit config;
    inherit lib;
  };
  getPowerStatus =
    deviceId:
    pkgs.writeShellScript "get-power-status.sh" ''
      ${pkgs.smartmontools}/bin/smartctl -i -d ata -n standby /dev/disk/by-id/${deviceId}
    '';
in
{
  options.monitoring.disks = lib.mkOption {
    type = lib.types.listOf (
      lib.types.submodule {
        options = {
          name = lib.mkOption {
            type = lib.types.str;
            description = "Script name exposed by the script exporter.";
          };

          device = lib.mkOption {
            type = lib.types.str;
            description = "Disk device identifier passed to getPowerStatus.";
          };
        };
      }
    );

    default = [ ];
    description = "List of disks to monitor via the script exporter.";
  };
  config = {
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

    services.cadvisor = {
      enable = true;
      extraOptions = [
        "--housekeeping_interval=300s"
        "--disable_metrics=advtcp,app,cpu_topology,cpuset,hugetlb,memory_numa,network,oom_event,percpu,perf_event,process,referenced_memory,resctrl,sched,tcp,udp"
      ];
      port = 9003;
    };
    systemd.services."prometheus-script-exporter" = {
      #environment = {
      #SHELL = lib.getExe pkgs.bash;
      #};
      serviceConfig = {
        #      ExecStart = lib.mkForce "${lib.getExe pkgs.tmux} new-session -A -s systemd-debug";
        #      PrivateTmp = lib.mkForce false;
        #      RestrictAddressFamilies = lib.mkForce [];
        #      Type = "forking";
        #User = "root";
        PrivateDevices = "no";
        AmbientCapabilities = [
          "CAP_SYS_RAWIO"
          "CAP_SYS_ADMIN"
        ];
        CapabilityBoundingSet = [
          "CAP_SYS_RAWIO"
          "CAP_SYS_ADMIN"
        ];
        DevicePolicy = "closed";
        DeviceAllow = lib.mkOverride 50 [
          "block-blkext rw"
          "block-sd rw"
          "char-nvme rw"
        ];
        ProtectProc = "invisible";
        ProcSubset = "pid";
        SupplementaryGroups = [
          "disk"
          #        "smartctl-exporter-access"
        ];
        SystemCallFilter = [
          "@system-service"
          "~@privileged"
        ];
      };
    };

    services.prometheus = {
      enable = true;
      port = 9001;
      exporters = lib.mkMerge [
        {
          node = {
            enable = true;
            #          enabledCollectors = [ "processes" "systemd" ];
            #          extraFlags = [ "--collector.systemd.unit-include='.*'" ];
            port = 9002;
          };
          systemd = {
            enable = true;
            listenAddress = "localhost";
          };
          script = {
            enable = true;
            port = 9104;

            settings.scripts = map (disk: {
              name = disk.name;
              command = [ (getPowerStatus disk.device) ];
            }) config.monitoring.disks;
          };

        }
        (lib.optionalAttrs (config.boot.supportedFilesystems.zfs or false) {
          zfs = {
            enable = true;
            listenAddress = "localhost";
          };
        })
        #        smartctl = {
        #          enable = true;
        #          listenAddress = "localhost";
        #          maxInterval = "5m";
        #        };
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

      scrapeConfigs = [
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
          scheme = "https";
          metrics_path = "/api/prometheus";
          bearer_token_file = config.sops.secrets.homeassistant-access-token.path;
          static_configs = [
            {
              targets = [ "homeassistant.internal.luqasn.org:443" ];
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
        {
          job_name = "cadvisor";
          params = {
            max_age = [ "1s" ];
          };
          static_configs = [
            { targets = [ "127.0.0.1:${toString config.services.cadvisor.port}" ]; }
          ];
        }
      ]
      ++ map (disk: {
        job_name = "script-${disk.name}";
        metrics_path = "/probe";
        params = {
          script = [ disk.name ];
        };
        static_configs = [
          {
            targets = [
              "127.0.0.1:${toString config.services.prometheus.exporters.script.port}"
            ];
          }
        ];
      }) config.monitoring.disks
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
  };
}
