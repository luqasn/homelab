{ lib, config }:
{
  mkVirtualHost =
    {
      port ? null,
      internal,
      settings ? { },
    }@args:
    {
      forceSSL = true;
      useACMEHost = config.common.domain;

      listenAddresses = lib.mkIf internal [
        config.common.internalIp
      ];
      locations."/" = (lib.optionalAttrs (port != null) {
          proxyPass = "http://127.0.0.1:${toString port}";
        }) // settings;
    };
}
