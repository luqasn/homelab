{
  pkgs,
  lib,
  config,
  ...
}:
let
  secrets = import "../../secrets/git-crypt.nix";
  offsiteBackupHost = "192.168.178.4";
  offsiteBackupHostIpmi = "192.168.178.5";
  smartSwitchHost = "192.168.178.7";
in
{
  imports = [
    # contains your disk format and partitioning configuration.
    ../../modules/disko.nix
    # this file is shared among all machines
    ../../modules/shared.nix
    ../../modules/remote-unlock.nix
    ../../modules/remote-unlock-tailscale.nix
    ../../modules/homelab.nix
    ../../modules/jellyfin.nix
    ../../modules/nextcloud.nix
    ../../modules/vaultwarden.nix
    ../../modules/homelab-backup-keys.nix
    ../../modules/monitoring.nix
    ../../modules/actual.nix
    ../../modules/adguard.nix
    ../../modules/starr
  ];

  services.tailscale = {
    enable = true;
    authKeyFile = pkgs.writeText "ts-authkey" "tskey-auth-ky3Vdtm9i721CNTRL-5EAGkLHfsX24fKaY4k7PY22UTHrb3KQrZ";
    interfaceName = "userspace-networking";
  };

  # homelab settings
  common.domain = secrets.domain.prod;

  nixpkgs.config.allowUnfree = true;
  mares.starr = {
    enable = true;
    sabnzbd = {
      enable = true;
      bindAddress = "127.0.0.1";
    };
    radarr.enable = true;
    prowlarr.enable = true;
    sonarr = {
      enable = true;
      bindAddress = "127.0.0.1";
    };
  };

  common.internalIp = "192.168.1.9";
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

  # This is your user login name.
  users.users.user.name = "lucas";

  boot.zfs = {
    #      requestEncryptionCredentials = [ "zroot" ];
    requestEncryptionCredentials = true;
  };

  # Find out the required network card driver by running `lspci -k` on the target machine
  boot.initrd.kernelModules = [ "e1000e" ];
  boot.kernelModules = [ "e1000e" ];
  systemd.enableEmergencyMode = false;

  boot = {
    supportedFilesystems = [ "zfs" ];
    kernelParams = [
      "intel_iommu=on"
      "iommu=pt"
    ];
  };

  services.zfs.autoScrub.enable = true;

  systemd.targets.offsite-backup = {
    description = "Backup Job Target";
    wantedBy = [ "timers.target" ];
  };

  sops.templates."offsite-backup-on".content = ''
    echo "Turning on power outlet"
    curl "http://${smartSwitchHost}/cm?cmnd=Power%20ON"

    echo "Turning on power via IPMI"
    while ! ipmitool -H ${offsiteBackupHostIpmi} -U ${config.sops.placeholder.ipmi-username} -P ${config.sops.placeholder.ipmi-password} power on 2>&1; do
      echo "IPMI command failed, retrying"
      sleep 5
    done
    echo
  '';

  sops.templates."offsite-backup-off".content = ''
    ipmitool -H ${offsiteBackupHostIpmi} -U ${config.sops.placeholder.ipmi-username} -P ${config.sops.placeholder.ipmi-password} power soft
    echo "Waiting for shutdown..."
    while true; do
      echo "still waiting"
      output=$(ipmitool -H ${offsiteBackupHostIpmi} -U ${config.sops.placeholder.ipmi-username} -P ${config.sops.placeholder.ipmi-password} power status)
      if [[ "$output" == *"Power is off"* ]]; then # Check if the output contains "Power is off"
        echo "Power is off. Exiting loop."
        break
      fi
      sleep 5
    done
    curl "http://${smartSwitchHost}/cm?cmnd=Power%20OFF"
  '';

  systemd.services.turn-on = {
    path = with pkgs; [
      curl
      ipmitool
    ];
    description = "Turn on offsite-backup socket and server";
    partOf = [ "offsite-backup.target" ];
    before = [ "offsite-backup.service" ];
    TimeoutSec = 300;
    serviceConfig = {
      Type = "oneshot";
      ExecStart = config.sops.templates."offsite-backup-on".path;
    };
  };

  systemd.services.offsite-backup = {
    description = "Run backup script";
    partOf = [ "offsite-backup.target" ];
    after = [ "turn-on.service" ];
    requires = [ "turn-on.service" ];
    before = [ "turn-off.service" ];
    path = with pkgs; [
      hostname
      zfs
      zfs-autobackup
      openssh
    ];
    script = ''
      zfs-autobackup -v --clear-mountpoint --destroy-missing 14d --no-holds --set-properties readonly=on --ssh-target 192.168.178.4 offsite backup/proxmox
    '';
    serviceConfig = {
      Type = "oneshot";
    };

  };

  systemd.services.turn-off = {
    path = with pkgs; [
      curl
      ipmitool
    ];
    TimeoutSec = 300;
    description = "Turn off backup socket";
    partOf = [ "backup.target" ];
    after = [ "backup.service" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = config.sops.templates."offsite-backup-off".path;
    };
  };

  systemd.timers.offsite-backup = {
    description = "Run the full offsite-backup sequence";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "daily";
      #          OnCalendar = "hourly";
      Persistent = true;
      Unit = "offsite-backup.target";
    };
    #      unitConfig = {
    #        Unit = "backup.target";
    #      };
  };

  systemd = {
    #    services = {
    #      zfs-auto-snapshot = {
    #        path = with pkgs; [ hostname zfs zfs-autobackup openssh ];
    #        script = ''
    #        zfs-autobackup -v --clear-mountpoint --destroy-missing 14d --no-holds --set-properties readonly=on --ssh-target 192.168.178.4 offsite backup/proxmox
    #        '';
    #        serviceConfig = {
    #          Type = "oneshot";
    #        };
    #      };
    #    };
    #    timers = {
    #     zfs-auto-snapshot = {
    #        wantedBy = [ "timers.target" ];
    #        partOf = [ "zfs-auto-snapshot.service" ];
    #        timerConfig = {
    #          OnCalendar = "daily";
    ##          OnCalendar = "hourly";
    #          Persistent = true;
    #          Unit = "zfs-auto-snapshot.service";
    #        };
    #      };
    #    };
  };

  fileSystems."/data/jellyfin" = {
    device = "ssd/data/jellyfin";
    fsType = "zfs";
  };
  fileSystems."/data/nextcloud" = {
    device = "ssd/data/nextcloud/config";
    fsType = "zfs";
  };
  fileSystems."/data/nextcloud/data" = {
    device = "small/data/nextcloud/files";
    fsType = "zfs";
    options = [ "nofail" ];
  };

  fileSystems."/data/postgres" = {
    device = "ssd/data/postgres";
    fsType = "zfs";
  };

  fileSystems."/media" = {
    device = "small/apps/mtv_dl/data";
    fsType = "zfs";
    options = [ "nofail" ];
  };

  datasets.postgres = "/data/postgres";
  datasets.nextcloud = "/data/nextcloud";

  services.jellyfin.dataDir = "/data/jellyfin";
  services.jellyfin.configDir = "/data/jellyfin/config";

  #  security.acme.defaults.server = "https://acme-staging-v02.api.letsencrypt.org/directory";

  powerManagement.powertop.enable = true;

  # Set this for clan commands use ssh i.e. `clan machines update`
  # If you change the hostname, you need to update this line to root@<new-hostname>
  # This only works however if you have avahi running on your admin machine else use IP
  clan.core.networking.targetHost = "root@elserver";

  # You can get your disk id by running the following command on the installer:
  # Replace <IP> with the IP of the installer printed on the screen or by running the `ip addr` command.
  # ssh root@<IP> lsblk --output NAME,ID-LINK,FSTYPE,SIZE,MOUNTPOINT
  disko.devices.disk.main.device = "/dev/disk/by-id/wwn-0x500a0751e9aa7368";

  # IMPORTANT! Add your SSH key here
  # e.g. > cat ~/.ssh/id_ed25519.pub
  users.users.root.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOJLoEv6NFo+psb7VFAqeUv1PiIdFyvLGxPLT3+3uvzI luqasn@gmail.com"
  ];

  programs.ssh.extraConfig = ''
    Host *
      IdentityFile ${config.clan.core.vars.generators.ssh-key-root.files."id_ed25519".path}
  '';

  # Zerotier needs one controller to accept new nodes. Once accepted
  # the controller can be offline and routing still works.
  clan.core.networking.zerotier.controller.enable = false;
}
