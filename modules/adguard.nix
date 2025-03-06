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
    port = 3003;
    settings = {
      #      bind_port = 3003;
      schema_version = 20;
      dhcp.enabled = false;
      http = {
        # You can select any ip and port, just make sure to open firewalls where needed
        address = "127.0.0.1:${toString config.services.adguardhome.port}";
      };

      user_rules = [
        "@@||brevo.com^$important"
      ];

      dns = {
        ratelimit = 0;
        bind_hosts = [ "0.0.0.0" ];
        upstream_dns = [
          # Example config with quad9
          "9.9.9.9"
          "149.112.112.112"
          # Uncomment the following to use a local DNS service (e.g. Unbound)
          # Additionally replace the address & port as needed
          # "127.0.0.1:5335"
        ];
      };
      filtering = {
        protection_enabled = true;
        filtering_enabled = true;

        parental_enabled = false; # Parental control-based DNS requests filtering.
        safe_search = {
          enabled = false; # Enforcing "Safe search" option for search engines, when possible.
        };
      };
    };
  };

  services.nginx.virtualHosts."adguard.${config.common.internalDomain}" = utils.mkVirtualHost {
    port = config.services.adguardhome.port;
    internal = true;
  };
}
