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
  clan.core.vars.generators.freshrss-password = {
    files."pw".secret = true;

    prompts.pw.description = "the password";
    prompts.pw.type = "hidden";

    script = ''
        cat "$prompts/pw" > "$out/pw"
    '';
  };

  sops.secrets.freshrss-password = {
    owner = "freshrss";
    group = "freshrss";
  };

  services.freshrss = {
    enable = true;
    defaultUser = "lucas";
    passwordFile = config.sops.secrets.freshrss-password.path;
    baseUrl = "https://rss.${config.common.internalDomain}";
    virtualHost = "rss.${config.common.internalDomain}";
  };

  services.nginx.virtualHosts."rss.${config.common.internalDomain}" = utils.mkVirtualHost {
      internal = true;
  };

}