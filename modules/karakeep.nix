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
  # The bundled `karakeep` service is built from source with a pnpm pinned to
  # an insecure revision (pnpm-9.15.9: CVE-2026-48995, CVE-2026-50014, ...).
  # It's a build-time-only tool distinct from the runtime, so we permit it
  # rather than pin a patched pnpm here. Revisit/remove once nixpkgs ships an
  # updated karakeep that no longer depends on this pnpm.
  nixpkgs.config.permittedInsecurePackages = [
    "pnpm-9.15.9"
    "immich-2.7.5"
  ];
  services.meilisearch.package = pkgs-meilisearch.meilisearch;

  services.karakeep = {
    enable = true;

    # nixpkgs' default `nodejs` is 24.19.0, which backported the
    # `node::ObjectWrap` cleanup hooks without the accompanying cleanup-hook
    # registry (nodejs/node#65446). better-sqlite3's `Statement` destructor then
    # calls `RemoveEnvironmentCleanupHook` with no live Environment during GC and
    # aborts the process:
    #   Statement::~Statement -> node::ObjectWrap::~ObjectWrap
    #   -> RemoveEnvironmentCleanupHook -> Assertion `(env) != nullptr' failed
    # Node 22 is LTS and predates that change, so build/run Karakeep with it.
    # Drop this override once nixpkgs ships a nodejs without this regression
    # (see nodejs/node#65446).
    package = pkgs.karakeep.override { nodejs = pkgs.nodejs_22; };

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
