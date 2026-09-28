{
  config,
  lib,
  ...
}:
let
  # Forgejo is served on the internal domain by modules/forgejo.nix; Renovate
  # talks to it over the Gitea-compatible API (Forgejo is a Gitea fork).
  forgejoDomain = "forgejo.${config.common.internalDomain}";
in
{
  # Personal access token for the Renovate bot Forgejo user. Add it with:
  #   clan secrets set renovate-token --machine elserver
  # then grant the token the `repo` scope (read/write) in Forgejo.
  sops.secrets.renovate-token = { };

  services.renovate = {
    enable = true;
    schedule = "*-*-* 03:00:00";
    settings = {
      platform = "gitea";
      endpoint = "https://${forgejoDomain}/api/v1";
      onboardingConfig = {
        extends = [ "config:recommended" ];
      };
      autodiscover = true;
    };
    credentials = {
      RENOVATE_TOKEN = config.sops.secrets.renovate-token.path;
    };
  };
}
