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
    ./disko.nix
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
    ../../modules/coder/microvm-host.nix
#    ../../modules/starr
    #    ../../modules/starr/options.nix
    #    ../../modules/starr/sabnzbd
    #    ../../modules/homeassistant.nix
  ];

  # Coder microvm.nix host: workspace VMs run here, managed by the Coder
  # server on elserver. The provisioner SSHes in as root using the shared
  # `coder-provisioner-key` var (provisioner-key.nix) — its public key is
  # added to root's authorized_keys automatically by microvm-host.nix, so no
  # manual key paste is needed. Deploy elserver first to generate the keypair.
  coder.microvm = {
    enable = true;
    externalInterface = "eno1";
  };

  # Resolve the Coder server hostname to elserver's internal IP so
  # offsite-backup itself (and workspace VMs, via the template's own /etc/hosts
  # entry) can phone home. The Coder server runs on elserver, which uses
  # secrets.domain.prod, so the hostname is coder.internal.<prod-domain>
  # (coder.${config.common.internalDomain} on elserver). elserver's LAN IP is
  # routable from offsite-backup. Keep in sync with common.internalIp in
  # machines/elserver/configuration.nix.
  networking.hosts."192.168.1.9" = [ "coder.internal.${secrets.domain.prod}" ];

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


  monitoring.disks = [
    {
      name = "power-hdd-Z140A19XFVGG";
      device = "ata-TOSHIBA_MG08ACA16TE_Z140A19XFVGG";
    }
  ];

  # Expose the zfs exporter on the LAN so elserver's Prometheus can scrape
  # offsite-backup's snapshot timestamps directly (see modules/offsite-backup.nix
  # on elserver). Overrides the `localhost` default from monitoring.nix.
  # Firewall is disabled (modules/homelab.nix), so no port opening needed.
  services.prometheus.exporters.zfs.listenAddress = lib.mkForce "0.0.0.0";

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
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIR8NsEuDEGCRn1vm6Tcn5D5RhAqy/tRxkyE4kX6WUv/ homelab"
  ];

  users.users.root.openssh.authorizedKeys.keyFiles = [
    config.clan.core.vars.generators.ssh-key-root.files."id_ed25519.pub".path
  ];

  system.stateVersion = "25.05";
}
