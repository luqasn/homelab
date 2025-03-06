{ config, pkgs, ... }:
{
  boot.initrd.systemd = {
    enable = true;
  };

  clan.core.vars.generators.initrd-ssh = {
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

  boot.initrd.network = {
    enable = true;

    ssh = {
      enable = true;
      port = 2222;
      authorizedKeys = config.users.users.root.openssh.authorizedKeys.keys;
      hostKeys = [
        config.clan.core.vars.generators.initrd-ssh.files.id_ed25519.path
      ];
    };
  };

  boot.initrd.availableKernelModules = [
    "xhci_pci"
  ];
}
