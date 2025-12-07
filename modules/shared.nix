{
  config,
  clan-core,
  pkgs,
  lib,
  ...
}:
{
  imports = [
    # Enables the OpenSSH server for remote access
    clan-core.clanModules.sshd
    # Set a root password
    clan-core.clanModules.root-password
    clan-core.clanModules.user-password
    clan-core.clanModules.state-version
  ];

  time.timeZone = "Europe/Berlin";

  # Locale service discovery and mDNS
  services.avahi.enable = true;

  boot.loader.grub.configurationLimit = 10;
  boot.loader.systemd-boot.configurationLimit = 10;

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

#  services.smartd = {
#    enable = true;
#    defaults.monitored = "-a -n standby,25";
#    defaults.autodetected = "-a -n standby,25";
##    defaults.autodetected = [
##        "-a" "-n" "standby,25"
##    ];
#  };

  services.udev.extraRules =
    let
      mkRule = as: lib.concatStringsSep ", " as;
      mkRules = rs: lib.concatStringsSep "\n" rs;
    in
    mkRules ([
      (mkRule [
        ''ACTION=="add|change"''
        ''SUBSYSTEM=="block"''
        ''KERNEL=="sd[a-z]"''
        ''ATTR{queue/rotational}=="1"''
        ''RUN+="${pkgs.hdparm}/bin/hdparm -B 90 -S 242 /dev/%k"''
      ])
    ]);
}
