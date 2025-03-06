{
  config,
  pkgs,
  inputs,
  lib,
  ...
}:
{
  imports = [
    inputs.hoopsnake.nixosModules.default
  ];

  boot.initrd = {
    network = {
      enable = true;
    };
    systemd.extraBin.ping = "${pkgs.iputils}/bin/ping";
    systemd = {
      enable = true;
    };
  };

  clan.core.vars.generators.initrd-ssh-hoopsnake = {
    files."id_ed25519".neededFor = "activation";
    files."id_ed25519.pub".secret = false;
    runtimeInputs = [
      pkgs.coreutils
      pkgs.openssh
    ];
    script = ''
      ssh-keygen -t ed25519 -N "" -f "$out/id_ed25519"
    '';
  };

  clan.core.vars.generators.hoopsnake-tailscale-client-secret = {
    share = true;
    # bit of a weird one: because normal secrets don't work during activation
    # which is required for initrd setup, we need to use this "dummy" var
    # that is basically a "pass-through"
    prompts.client-secret.description = "the client secret";
    prompts.client-secret.type = "hidden";
    files.client-secret.secret = true;
    files.client-secret.neededFor = "activation";
    script = ''
      cat "$prompts/client-secret" > "$out/client-secret"
    '';
  };

  boot.initrd.systemd.services.hoopsnake = {
    wants = [ "network-online.target" ];
  };

  boot.initrd.network.hoopsnake = {
    enable = true;
    systemd-credentials = {
      privateHostKey.file = config.clan.core.vars.generators.initrd-ssh-hoopsnake.files.id_ed25519.path;
      privateHostKey.encrypted = false;

      clientId.text = "k3YA241CfD11CNTRL";
      clientId.encrypted = false;
      clientSecret.file =
        config.clan.core.vars.generators.hoopsnake-tailscale-client-secret.files.client-secret.path;
      clientSecret.encrypted = false;
    };
    ssh = {
      authorizedKeysFile = pkgs.writeText "authorized_keys" (
        lib.concatStringsSep "\n" config.users.users.root.openssh.authorizedKeys.keys
      );
    };
    tailscale = {
      name = "${config.networking.hostName}-unlock";
      tags = [ "tag:hoopsnake" ];
    };
  };

  boot.initrd.availableKernelModules = [
    "xhci_pci"
  ];
}
