{
  config,
  pkgs,
  lib,
  ...
}:
{
  imports = [
    (builtins.fetchTarball {
      # Pick a release version you are interested in and set its hash, e.g.
      url = "https://gitlab.com/simple-nixos-mailserver/nixos-mailserver/-/archive/6005d88bed7a5418f9772b4058a73cd0fd1e69a1/nixos-mailserver-6005d88bed7a5418f9772b4058a73cd0fd1e69a1.tar.gz";
      # To get the sha256 of the nixos-mailserver tarball, we can use the nix-prefetch-url command:
      # release="nixos-25.05"; nix-prefetch-url "https://gitlab.com/simple-nixos-mailserver/nixos-mailserver/-/archive/${release}/nixos-mailserver-${release}.tar.gz" --unpack
      sha256 = "0dkcnnmbfc2hydszhr3053fglbq1bah129dspqv75nssk25zcm6s";
    })
  ];
  services.postfix.enable = lib.mkForce false;
  #  services.mail.sendmailSetuidWrapper.setgid = lib.mkForce true;

  #  services = {
  #    postfix = {
  #      enable = true;
  #
  #      config = {
  #        ##
  #        ## Relay all mail via mail.smtp2go.com:2525
  #        ##
  #        relayhost = "[mail.smtp2go.com]:2525";
  #
  #        ##
  #        ## Enable SASL with static user/pass so that your Postfix
  #        ## always uses these credentials for the outgoing relay.
  #        ##
  #        smtp_sasl_auth_enable        = "yes";
  #        smtp_sasl_password_maps      = "static:<UserName>:<Password>";
  #        smtp_sasl_security_options   = "noanonymous";
  #        smtp_tIs_security_level = "may";
  #
  #        ##
  #        ## Optional: concurrency limit or other items SMTP2GO suggests
  #        ##
  #        smtp_destination_concurrency_limit = "20";
  #        header_size_limit = "4096000";
  #      };
  #    };

  users.users.postfix.group = "postfix";
  users.users.postfix.isSystemUser = true;
  users.groups.postfix = { };

  services.roundcube = {
    enable = true;
    # this is the url of the vhost, not necessarily the same as the fqdn of
    # the mailserver
    hostName = "webmail.${config.common.domain}";
    extraConfig = ''
      # starttls needed for authentication, so the fqdn required to match
      # the certificate
      $config['smtp_host'] = "tls://${config.mailserver.fqdn}";
      $config['smtp_user'] = "%u";
      $config['smtp_pass'] = "%p";
      $config['imap_host'] = "ssl://${config.mailserver.fqdn}:993";
    '';
  };

  services.nginx.virtualHosts.${config.services.roundcube.hostName} = {
    enableACME = false;
    useACMEHost = "${config.common.domain}";
  };

  clan.core.vars.generators.mail-password = {
    files."mailpw".secret = true;
    runtimeInputs = [
      pkgs.mkpasswd
    ];

    prompts.pw.description = "the mail password";
    prompts.pw.type = "hidden";

    script = ''
        cat "$prompts/pw" | mkpasswd -sm bcrypt > "$out/mailpw"
    '';
  };

  mailserver = {
    enable = true;
    stateVersion = 3;
    localDnsResolver = false;
    certificateScheme = "acme";
    acmeCertificateName = config.common.domain;
    fqdn = "mx.${config.common.domain}";
    domains = [ "romeromail.de" ];

    fullTextSearch = {
      enable = true;
      # index new email as they arrive
      autoIndex = true;
      enforced = "body";
      memoryLimit = 2000;
      languages = [
        "en"
        "de"
      ];
    };

    loginAccounts = {
      "lucas@romeromail.de" = {
        hashedPasswordFile = config.clan.core.vars.generators.mail-password.files.mailpw.path;
      };
    };

  };
}
