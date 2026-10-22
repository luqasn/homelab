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
  requestsHardened = pkgs.python3Packages.requests-hardened.overrideAttrs (old: {
    postPatch = (old.postPatch or "") + ''
      substituteInPlace pyproject.toml \
        --replace-fail 'uv_build>=0.11.0,<0.12.0' 'uv_build>=0.11.0,<0.13.0'
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