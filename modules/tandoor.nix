{
  pkgs,
  lib,
  config,
  self,
  ...
}:
let
  utils = import ../lib {
    inherit config;
    inherit lib;
  };
  tandoorHttpPort = 9768;

  # nixpkgs' uv-build is 0.12, while requests-hardened 1.3.0 still pins
  # `uv_build>=0.11.0,<0.12.0`, so its PEP 517 build aborts before compiling.
  # The backend is compatible; widen the constraint until upstream/nixpkgs
  # catches up.
  #
  # Use sed rather than substituteInPlace: the pattern contains `>` and `<`,
  # which the current stdenv turns into sed word-boundary anchors, so
  # substituteInPlace never matches. Replace the base postPatch entirely; its
  # only job is this same substitution.
  requestsHardened = pkgs.python3Packages.requests-hardened.overrideAttrs (_: {
    postPatch = ''
      sed -i 's/uv_build>=0.11.0,<0.12.0/uv_build>=0.11.0,<0.13.0/' pyproject.toml
    '';
  });

  tandoorRecipes = pkgs.tandoor-recipes.overrideAttrs (old: {
    propagatedBuildInputs = map (
      pkg: if lib.getName pkg == "requests-hardened" then requestsHardened else pkg
    ) old.propagatedBuildInputs;
  });
in
{
    services.tandoor-recipes = {
      enable = true;
      package = tandoorRecipes;
      database.createLocally = true;
      port = tandoorHttpPort;

      extraConfig = {
        SECRET_KEY_FILE = config.sops.secrets.tandoor-secret.path;
        GUNICORN_MEDIA = "1";
        ALLOWED_HOSTS = "recipes.${config.common.internalDomain}";
        TZ = "Europe/Berlin";
      };
    };
  services.nginx.virtualHosts."recipes.${config.common.internalDomain}" = utils.mkVirtualHost {
    port = tandoorHttpPort;
    internal = true;
  };
}