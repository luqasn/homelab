{
  config,
  pkgs,
  lib,
  self,
  ...
}:
let
  secrets = import "${self}/secrets/git-crypt.nix";
  mail-sync-pkg = pkgs.writeShellApplication {
    name = "mail-sync";

    runtimeInputs = [
      pkgs.imapsync
    ];

    text = ''
      IMAPSYNC_PASSWORD1=$(cat "$CREDENTIALS_DIRECTORY/pw1")
      IMAPSYNC_PASSWORD2=$(cat "$CREDENTIALS_DIRECTORY/pw2")
      export IMAPSYNC_PASSWORD1 IMAPSYNC_PASSWORD2
      imapsync --nolog --tmpdir /tmp \
        --host1 ${secrets.mailhost} --port1 993 --ssl1 \
        --user1 lucas@romeromail.de \
        --host2 localhost --ssl2 \
        --user2 lucas@romeromail.de \
        --folder INBOX \
        --folder Sent \
        --folder Drafts
    '';
  };
in
{
  imports = [ self.inputs.nixos-mailserver.nixosModules.mailserver ];
  services.postfix.enable = lib.mkForce false;

  users.users.postfix.group = "postfix";
  users.users.postfix.isSystemUser = true;
  users.groups.postfix = { };

  services.roundcube = {
    enable = true;
    # this is the url of the vhost, not necessarily the same as the fqdn of
    # the mailserver
    hostName = "webmail.${config.common.internalDomain}";
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

    listenAddresses = [
      config.common.internalIp
    ];
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

  systemd.services.mail-sync = {
    description = "Sync mail via imapsync";
    after = [ "network-online.target" "sops-nix.service"];
    wants = [ "network-online.target" "sops-nix.service"];

    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${mail-sync-pkg}/bin/mail-sync";

      LoadCredential = [
          "pw1:${config.sops.secrets.mail-sync-pw1.path}"
          "pw2:${config.sops.secrets.mail-sync-pw2.path}"
      ];
      # Hardening
      DynamicUser           = true;
      CapabilityBoundingSet = "";
      PrivateDevices        = true;
      ProtectHome           = true;
      ProtectSystem         = "strict";
      NoNewPrivileges       = true;
    };
  };

  systemd.timers.mail-sync = {
    description = "Run mail sync every day";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "daily";
      Persistent = true;
      Unit = "mail-sync.service";
    };
  };

}
