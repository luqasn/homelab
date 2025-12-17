{
  pkgs,
  lib,
  config,
  self,
  ...
}:
let
  secrets = import "${self}/secrets/git-crypt.nix";
  utils = import ../../lib {
    inherit config;
    inherit lib;
  };
in
{
  imports = [
    # contains your disk format and partitioning configuration.
    ../../modules/disko.nix
    # this file is shared among all machines
    ../../modules/shared.nix
    #    ../../modules/remote-unlock.nix
    #    ../../modules/remote-unlock-tailscale.nix
    ../../modules/homelab.nix
#    ../../modules/jellyfin.nix
    ../../modules/homelab-backup-keys.nix
    #    ../../modules/nextcloud.nix
    ../../modules/vaultwarden.nix
    ../../modules/monitoring.nix
#    ../../modules/starr
    #    ../../modules/starr/options.nix
    #    ../../modules/starr/sabnzbd
    #    ../../modules/homeassistant.nix
  ];

  services.tailscale = {
    enable = true;
    authKeyFile = pkgs.writeText "ts-authkey" "tskey-auth-kSXbuMVREY11CNTRL-uXCdijqDHuK6dJDUJJPQvKkPrhLvPA8e";
    interfaceName = "userspace-networking";
  };

  # homelab settings
  common.domain = secrets.domain.stage;
  datasets.postgres = "/data/postgres";

  nixpkgs.config.allowUnfree = true;
#  mares.starr = {
#    enable = true;
#    sabnzbd = {
#      enable = true;
#      bindAddress = "127.0.0.1";
#    };
#    radarr.enable = true;
#    prowlarr.enable = true;
#  };

  # This is your user login name.
#  users.users.user.name = "lucas";

  systemd.enableEmergencyMode = false;
  disko.encryptedRoot.enable = false;
  boot.zfs = {
    requestEncryptionCredentials = false;
  };

  # Find out the required network card driver by running `lspci -k` on the target machine
  boot.kernelModules = [ "igb" ];
  boot.initrd.kernelModules = [ "igb" ];

  boot = {
    supportedFilesystems = [ "zfs" ];
  };

  fileSystems."/data" = {
    device = "backup/data";
    fsType = "zfs";
  };

  #  fileSystems."/data/nextcloud" = {
  #    device = "backup/data/nextcloud";
  ##    device = "backup/nixos/data/nextcloud";
  #    fsType = "zfs";
  #  };
  #  fileSystems."/data/nextcloud/data" = {
  #    #    device = "backup/data/nextcloud";
  #    device = "backup/proxmox/small/data/nextcloud/files";
  #    fsType = "zfs";
  #    options = [ "nofail" ];
  #  };

  #  datasets.nextcloud = "/data/nextcloud";

  #  users.users.nextcloud = lib.mkIf config.services.nextcloud.enable {
  #    #    uid = 100033;
  #    #    group = "nextcloud";
  #  };

  fileSystems."/data/postgres" = {
    device = "backup/data/postgres";
    fsType = "zfs";
  };

  fileSystems."/media" = {
    device = "backup/proxmox/small/apps/mtv_dl/data";
    fsType = "zfs";
  };

  powerManagement.powertop.enable = true;

  common.internalIp = "192.168.178.9";
  networking = {
    interfaces = {
      eno1 = {
        useDHCP = true;
        ipv4.addresses = [
          {
            address = config.common.internalIp;
            prefixLength = 24;
          }
        ];
      };
    };
  };

  # Set this for clan commands use ssh i.e. `clan machines update`
  # If you change the hostname, you need to update this line to root@<new-hostname>
  # This only works however if you have avahi running on your admin machine else use IP
  clan.core.networking.targetHost = "root@offsite-backup";

  # You can get your disk id by running the following command on the installer:
  # Replace <IP> with the IP of the installer printed on the screen or by running the `ip addr` command.
  # ssh root@<IP> lsblk --output NAME,ID-LINK,FSTYPE,SIZE,MOUNTPOINT
  disko.devices.disk.main.device = "/dev/disk/by-id/ata-MKNSSDSR250GB_MB1805181003E876E";

  # IMPORTANT! Add your SSH key here
  # e.g. > cat ~/.ssh/id_ed25519.pub
  users.users.root.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOJLoEv6NFo+psb7VFAqeUv1PiIdFyvLGxPLT3+3uvzI luqasn@gmail.com"
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIO8J4wpZiIVYgf5c/DbW0dIPKtjirE4XqVYUhUZEVxpM lucas@nixbook"
  ];

  users.users.root.openssh.authorizedKeys.keyFiles = [
    config.clan.core.vars.generators.ssh-key-root.files."id_ed25519.pub".path
  ];

  # Zerotier needs one controller to accept new nodes. Once accepted
  # the controller can be offline and routing still works.
  clan.core.networking.zerotier.controller.enable = false;
  system.stateVersion = "25.05";
}
