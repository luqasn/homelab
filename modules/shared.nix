{
  config,
  clan-core,
  pkgs,
  lib,
  self,
  ...
}:
{
  imports = [
    # Per-system OpenVEX feed for the vulnerability scan
    # (.forgejo/workflows/vuln-scan.yml): adds `system.build.vexFeed`, which
    # grype consumes via `--vex`. It only reads config/pkgs and adds a binding,
    # so the running system is unchanged; statements it drops are surfaced as
    # build warnings for manual triage. See the flake input note in flake.nix.
    self.inputs.nixos-vex.nixosModules.default
  ];

#  imports = [
#    # Enables the OpenSSH server for remote access
#    clan-core.clanModules.sshd
#    # Set a root password
#    clan-core.clanModules.root-password
#    clan-core.clanModules.user-password
#    clan-core.clanModules.state-version
#  ];
#  clan.core.settings.state-version.enable = true;


  time.timeZone = "Europe/Berlin";

  # Collect Nix garbage automatically. Without this no `nix-gc.timer` is
  # generated and dead store paths/old generations accumulate in /nix forever
  # (on elserver /nix is the `zroot/local/nix` dataset, and the deploy pipeline
  # builds on elserver itself with `--build-host localhost`, so it grows fast).
  # Policy matches the Coder workspace template
  # (modules/coder/template/flake.nix.tftpl): weekly, drop anything unreferenced
  # for a fortnight.
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 14d";
  };

  # Locale service discovery and mDNS
  services.avahi.enable = true;

  boot.loader.grub.configurationLimit = 10;
  boot.loader.systemd-boot.configurationLimit = 10;

  # generate a random password for our user below
  # can be read using `clan secrets get <machine-name>-user-password` command
#  clan.user-password.user = "user";
#  users.users.user = {
#    isNormalUser = true;
#    extraGroups = [
#      "wheel"
#      "networkmanager"
#      "video"
#      "input"
#    ];
#    uid = 1000;
#    openssh.authorizedKeys.keys = config.users.users.root.openssh.authorizedKeys.keys;
#  };

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
