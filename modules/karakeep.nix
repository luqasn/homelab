{
  config,
  lib,
  pkgs,
  inputs,
  ...
}:
let
  utils = import ../lib {
    inherit config;
    inherit lib;
  };
  karakeepHttpPort = 8778;

  # nixpkgs 26.05 ships meilisearch 1.43.1, but Karakeep's index was migrated by
  # meilisearch 1.45.2 at some point. Meilisearch is one-way: when the on-disk
  # database is newer than the binary it refuses to start with
  #   "Database version X is higher than the Meilisearch version Y."
  #   "Downgrade is not supported"
  # Use the dedicated `nixpkgs-meilisearch` input, pinned to the nixpkgs commit
  # that ships exactly meilisearch 1.45.2. Drop that input (and this binding)
  # once the pinned nixpkgs ships meilisearch >= 1.45.2.
  pkgs-meilisearch =
    inputs.nixpkgs-meilisearch.legacyPackages.${pkgs.stdenv.hostPlatform.system};
in
{
  # nixpkgs 26.05 ships Immich 2.7.5, which carries known CVEs and is no longer
  # maintained upstream (Immich 3.x lives in the unstable channel). This homelab
  # still runs 2.7.5, so permit it rather than block evaluation.
  #
  # (Karakeep previously pulled an insecure pnpm 9.15.9; nixpkgs' karakeep 0.33.0
  # now builds with pnpm 11, so that permission has been dropped.)
  nixpkgs.config.permittedInsecurePackages = [
    "immich-2.7.5"
  ];
  services.meilisearch.package = pkgs-meilisearch.meilisearch;

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
