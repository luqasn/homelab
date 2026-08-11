{
  pkgs,
  lib,
  config,
  self,
  ...
}:
let
  secrets = import "${self}/secrets/git-crypt.nix";
  vaultwardenDir = "/data/vaultwarden";
in
{
  imports = [
    # contains your disk format and partitioning configuration.
    ./disko.nix
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
    ../../modules/karakeep.nix
    ../../modules/offsite-backup.nix
    ../../modules/odysseus.nix
    ../../modules/starr
    ../../modules/mailserver.nix
    ../../modules/immich.nix
    ../../modules/rss.nix
    ../../modules/tandoor.nix
    ../../modules/home-assistant
    ../../modules/kindle-todo
    ../../modules/tandoor-to-kindle
  ];

  nixpkgs.config.packageOverrides = pkgs: {
      intel-vaapi-driver = pkgs.intel-vaapi-driver.override { enableHybridCodec = true; };
    };

    systemd.services.jellyfin.environment.LIBVA_DRIVER_NAME = "iHD"; # or i965 for older GPUs
    environment.sessionVariables = { LIBVA_DRIVER_NAME = "iHD"; };

    hardware.graphics = {
      enable = true;

      extraPackages = with pkgs; [
        intel-ocl # Generic OpenCL support

        # For Broadwell and newer (ca. 2014+), use with LIBVA_DRIVER_NAME=iHD:
        intel-media-driver
      ];
    };
      # for hardware acceleration
      users.users.${config.services.jellyfin.user}.extraGroups = [
        "video"
        "render"
      ];
      systemd.services.jellyfin.serviceConfig = {
        DeviceAllow = lib.mkForce [ "/dev/dri/renderD128" ];
      };

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
    pathPrefix = "/data/starr";
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

  clan.core.vars.generators.second-stage-encryption-key = {
    prompts.key.description = "the key";
    prompts.key.type = "hidden";
    files.key = {
        secret = true;
        neededFor = "partitioning";
    };
    script = ''
      cat "$prompts/key" > "$out/key"
    '';
  };
  disko.secondStageKeyPath = config.clan.core.vars.generators.second-stage-encryption-key.files.key.path;

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
      "apm=power_off"
      "acpi=force"
      "reboot=acpi"
    ];
  };

  services.zfs.autoScrub.enable = true;
  services.zfs.autoSnapshot.enable = lib.mkForce false;

  systemd.services.prometheus.unitConfig.ConditionPathIsMountPoint = ["/var/lib/prometheus2"];
  fileSystems."/var/lib/prometheus2" = {
    device = "ssd/data/prometheus";
    fsType = "zfs";
  };
  fileSystems."/data/grafana" = {
    device = "ssd/data/grafana";
    fsType = "zfs";
  };
  fileSystems."${vaultwardenDir}" = {
    device = "ssd/data/vaultwarden";
    fsType = "zfs";
  };
  fileSystems."/data/starr" = {
    device = "ssd/data/starr";
    fsType = "zfs";
  };
  systemd.services.influxdb2.unitConfig.ConditionPathIsMountPoint = ["/var/lib/influxdb2"];
  fileSystems."/var/lib/influxdb2" = {
    device = "ssd/data/influxdb2";
    fsType = "zfs";
  };


  systemd.services.actual.unitConfig.ConditionPathIsMountPoint = ["/var/lib/private/actual"];
  fileSystems."/var/lib/private/actual" = {
    device = "ssd/data/actual";
    fsType = "zfs";
  };


  systemd.services.scrutiny.unitConfig.ConditionPathIsMountPoint = ["/var/lib/private/scrutiny"];
  fileSystems."/var/lib/private/scrutiny" = {
    device = "ssd/data/scrutiny";
    fsType = "zfs";
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
  fileSystems."/data/mail" = {
    device = "ssd/data/mail";
    fsType = "zfs";
  };

  fileSystems."/data/postgres" = {
    device = "ssd/data/postgres";
    fsType = "zfs";
  };

  fileSystems."/data/homeassistant" = {
    device = "ssd/data/homeassistant";
    fsType = "zfs";
  };

  fileSystems."/data/freshrss" = {
    device = "ssd/data/freshrss";
    fsType = "zfs";
  };

  services.freshrss.dataDir = "/data/freshrss";

  fileSystems."/data/icloud" = {
    device = "ssd/data/icloud";
    fsType = "zfs";
  };

  fileSystems."/media" = {
    device = "small/apps/mtv_dl/data";
    fsType = "zfs";
    options = [ "nofail" ];
  };

  mailserver = {
    mailDirectory = "/data/mail/mail";
    indexDir = "/data/mail/indices";
  };


  systemd.services.immich-server.unitConfig.ConditionPathIsMountPoint = ["/var/lib/immich"];
  fileSystems."/var/lib/immich" = {
    device = "small/data/immich";
    fsType = "zfs";
  };

  datasets.postgres = "/data/postgres";
  datasets.nextcloud = "/data/nextcloud";

  services.jellyfin.dataDir = "/data/jellyfin";
  services.jellyfin.configDir = "/data/jellyfin/config";

  services.grafana.dataDir = "/data/grafana";

#  services.sonarr.dataDir = "/data/starr/sonarr";
#  services.prowlarr.dataDir = "/data/starr/prowlarr";
#  services.radarr.dataDir = "/data/starr/radarr";

  services.sabnzbd.configFile = "/data/starr/sabnzbd/sabnzbd.ini";
#  systemd.services.sabnzbd = {
#    serviceConfig = {
#      StateDirectory = lib.mkOverride 50 "/data/starr/sabnzbd";
#    };
#  };

#  systemd.services.influxdb2.serviceConfig.StateDirectory = lib.mkOverride 50 "/data/influxdb2";

  services.vaultwarden.config.DATA_FOLDER = vaultwardenDir;
  systemd.services.vaultwarden = {
    serviceConfig = {
      StateDirectory = lib.mkOverride 50 vaultwardenDir;
      ReadWritePaths = [vaultwardenDir];
    };
  };

  systemd.services.karakeep.unitConfig.ConditionPathIsMountPoint = ["/var/lib/karakeep"];
  fileSystems."/var/lib/karakeep" = {
    device = "ssd/data/karakeep";
    fsType = "zfs";
  };

  # Odysseus persistent data (DB, uploads, ChromaDB vectors, generated images,
  # etc.) on its own ZFS dataset. Both the app and the bundled ChromaDB service
  # wait for the mount before starting so they never write into the empty
  # /var/lib root. dataDir is the module default /var/lib/odysseus.
  systemd.services.odysseus.unitConfig.ConditionPathIsMountPoint = ["/var/lib/odysseus"];
  systemd.services.odysseus-chroma.unitConfig.ConditionPathIsMountPoint = ["/var/lib/odysseus"];
  fileSystems."/var/lib/odysseus" = {
    device = "ssd/data/odysseus";
    fsType = "zfs";
  };



#  services.prometheus.stateDir = "prometheus2";
#  systemd.tmpfiles.rules = [
##    "D /var/lib/${config.services.prometheus.stateDir} 0751 prometheus prometheus - -"
##    "L+ /var/lib/${config.services.prometheus.stateDir}/data - - - - /data/prometheus/data"
##    "L+ /var/lib/influxdb2 - - - - /data/influxdb2"
##    "L+ /var/lib/vaultwarden - - - - /data/vaultwarden"
#  ];

  #  security.acme.defaults.server = "https://acme-staging-v02.api.letsencrypt.org/directory";

  monitoring.disks = [
    {
      name = "power-hdd-Z140A0SCFVGG";
      device = "ata-TOSHIBA_MG08ACA16TE_Z140A0SCFVGG";
    }
    {
      name = "power-hdd-Z140A0LAFVGG";
      device = "ata-TOSHIBA_MG08ACA16TE_Z140A0LAFVGG";
    }
  ];

  powerManagement.powertop.enable = true;

  # Set this for clan commands use ssh i.e. `clan machines update`
  # If you change the hostname, you need to update this line to root@<new-hostname>
  # This only works however if you have avahi running on your admin machine else use IP
  clan.core.networking.targetHost = "root@elserver";

  # You can get your disk id by running the following command on the installer:
  # Replace <IP> with the IP of the installer printed on the screen or by running the `ip addr` command.
  # ssh root@<IP> lsblk --output NAME,ID-LINK,FSTYPE,SIZE,MOUNTPOINT
  disko.devices.disk.main.device = "/dev/disk/by-id/nvme-Intenso_SSD_TD25060002782";

  # IMPORTANT! Add your SSH key here
  # e.g. > cat ~/.ssh/id_ed25519.pub
  users.users.root.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOJLoEv6NFo+psb7VFAqeUv1PiIdFyvLGxPLT3+3uvzI luqasn@gmail.com"
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIR8NsEuDEGCRn1vm6Tcn5D5RhAqy/tRxkyE4kX6WUv/ homelab"
  ];

  programs.ssh.extraConfig = ''
    Host *
      IdentityFile ${config.clan.core.vars.generators.ssh-key-root.files."id_ed25519".path}
  '';

  system.stateVersion = "25.05";
}
