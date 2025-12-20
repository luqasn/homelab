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
  imports = [
    # contains your disk format and partitioning configuration.
    ./adguard_filters.nix
  ];
  services.resolved = {
    enable = false;
  };
  services.adguardhome = {
    enable = true;
    port = 3333;
    settings = {
      #      bind_port = 3003;
      schema_version = 31;
      dhcp.enabled = false;
      http = {
        # You can select any ip and port, just make sure to open firewalls where needed
        address = "127.0.0.1:${toString config.services.adguardhome.port}";
      };

      user_rules = [
        "@@||brevo.com^$important"
        "@@||sentry-cdn.com^$important"
        "@@||meinkonto.telekom-dienste.de^$important"
        "@@||p5x.telekom.net^$important"
      ];

      dns = {
        ratelimit = 0;
        bind_hosts = [ "0.0.0.0" ];
        upstream_dns = [
          "86.54.11.100"
          "185.222.222.222"
          "45.11.45.11"
          "2a09::"
          "2a11::"
          "[/fritz.box/]192.168.1.1"
        ];
        fallback_dns = [
          "9.9.9.9"
          "149.112.112.112"
        ];
      };
      filtering = {
        protection_enabled = true;
        filtering_enabled = true;

        parental_enabled = false; # Parental control-based DNS requests filtering.
        safe_search = {
          enabled = false; # Enforcing "Safe search" option for search engines, when possible.
        };
        rewrites = [
          {
            domain = "*.internal.stage.${config.common.domain}";
            answer = "192.168.178.9";
            enabled = true;
          }
          {
            domain = "*.stage.${config.common.domain}";
            answer = "192.168.178.4";
            enabled = true;
          }
        ];
      };
    };
  };

  services.nginx.virtualHosts."adguard.${config.common.internalDomain}" = utils.mkVirtualHost {
    port = config.services.adguardhome.port;
    internal = true;
  };
}
