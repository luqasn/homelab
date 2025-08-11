{config, clan-core, ...}:{
  imports = [
    # contains your disk format and partitioning configuration.
    ../../modules/disko.nix
    # Enables the OpenSSH server for remote access
    clan-core.clanModules.sshd
    # Set a root password
    clan-core.clanModules.root-password
    clan-core.clanModules.user-password
    clan-core.clanModules.state-version
  ];

  # New machine!
  clan.core.networking.targetHost = "root@localhost:8022";
  disko.devices.disk.main.device = "/dev/sda";

boot.loader.grub = {
    enable = true;
    zfsSupport = true;
    efiSupport = true;
#    mirroredBoots = [
#      {
#        devices = [ "nodev" ];
#        path = "/boot1";
#      }
#      {
#        devices = [ "nodev" ];
#        path = "/boot2";
#      }
#    ];
  };

#  boot.loader.efi.canTouchEfiVariables = true;

  boot.supportedFilesystems = [ "zfs" ];

  # prevents "multiple pools with same name" problem during boot
  boot.zfs.devNodes = "/dev/disk/by-partuuid";


boot.loader.grub.mirroredBoots = [
  {
    devices = [
      "/dev/disk/by-uuid/26C0-89F8"
    ];
    path = "/boot1";
  }
  {
    devices = [
      "/dev/disk/by-uuid/5C5A-7091"
    ];
    path = "/boot2";
  }
];



  users.users.root.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOJLoEv6NFo+psb7VFAqeUv1PiIdFyvLGxPLT3+3uvzI luqasn@gmail.com"
  ];
  # generate a random password for our user below
  # can be read using `clan secrets get <machine-name>-user-password` command
  clan.user-password.user = "user";
  users.users.user = {
    isNormalUser = true;
    extraGroups = [
      "wheel"
      "networkmanager"
      "video"
      "input"
    ];
    uid = 1000;
    openssh.authorizedKeys.keys = config.users.users.root.openssh.authorizedKeys.keys;
  };


    networking.firewall = {
      enable = false;
      allowedTCPPorts = [
        80
        22
        ];
        };
}
