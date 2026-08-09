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
  karakeepHttpPort = 8778;
in
{
  # The bundled `karakeep` service is built from source with a pnpm pinned to
  # an insecure revision (pnpm-9.15.9: CVE-2026-48995, CVE-2026-50014, ...).
  # It's a build-time-only tool distinct from the runtime, so we permit it
  # rather than pin a patched pnpm here. Revisit/remove once nixpkgs ships an
  # updated karakeep that no longer depends on this pnpm.
  nixpkgs.config.permittedInsecurePackages = [
    "pnpm-9.15.9"
  ];
  services.karakeep = {
    enable = true;
    meilisearch.enable = true;
    browser.enable = true;

    extraEnvironment = {
      "PORT" = toString karakeepHttpPort;
      "NEXTAUTH_URL" = "https://karakeep.${config.common.domain}";
      "DISABLE_SIGNUPS" = "true";
    };
  };

  services.nginx.virtualHosts."karakeep.${config.common.domain}" = utils.mkVirtualHost {
    port = karakeepHttpPort;
    internal = false;
  };
}
