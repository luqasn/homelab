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
  karakeepHttpPort = 8778;
in
{
  services.karakeep = {
    enable = true;

    # nixpkgs' karakeep now pins nodejs_22 itself (nixpkgs commit 84a2f50,
    # "karakeep: fix worker crash by switching to nodejs_22") to dodge the
    # better-sqlite3 / nodejs 24 `ObjectWrap` cleanup-hook crash
    # (nodejs/node#65446). Our previous `override { nodejs = pkgs.nodejs_22; }`
    # is therefore obsolete — and the package no longer exposes a `nodejs`
    # argument, so overriding it fails outright.

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
