{ lib, config }:
{
  mkVirtualHost =
    {
      port,
      internal,
      settings ? { },
    }@args:
    {
      forceSSL = true;
      useACMEHost = config.common.domain;

      listenAddresses = lib.mkIf internal [
        config.common.internalIp
      ];
      locations."/" = {
        proxyPass = "http://127.0.0.1:${toString port}";
      } // settings;
    };
}
