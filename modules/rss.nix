{
config,
...
}:
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
    baseUrl = "https://rss.${config.common.domain}";
    virtualHost = "rss.${config.common.domain}";
  };

  services.nginx.virtualHosts."rss.${config.common.domain}" = {
    forceSSL = true;
    useACMEHost = config.common.domain;
  };

}