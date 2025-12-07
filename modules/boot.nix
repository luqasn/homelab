{
  lib,
  config,
  pkgs,
  ...
}:
with lib; {
  # Mount EFI and fix security warning for EFI mount
  # nixos-generate-config will generate this, but won't have the right options
#  fileSystems = optionalAttrs (config.fix-efi.enable) {
#    ${config.boot.loader.efi.efiSysMountPoint} = {
#      device = "/dev/disk/by-label/EFI";
#      fsType = "vfat";
#      options = ["fmask=0077" "dmask=0077"];
#    };
#  };

  boot = {
    initrd = {
      # Enable systemd in init
      systemd.enable = mkDefault true;

      kernelModules = [
        # Allow complex networking configurations during boot
        "macvlan"
        "bridge"
      ];
    };

    kernelParams = [
      "boot_on_fail"

      # Enable emergency access, even with root account locked
      # TODO: sync this with systemd.enableEmergencyMode
      "systemd.setenv=SYSTEMD_SULOGIN_FORCE=1"
    ];

    loader = {
      timeout = mkDefault 1;

      grub = {
        enable = mkDefault (!config.boot.loader.systemd-boot.enable);
        configurationLimit = mkDefault 8;
        splashImage = null; # I want all the text
        zfsSupport = mkDefault true;
        useOSProber = mkDefault true;
        efiSupport = mkDefault true;
        efiInstallAsRemovable = mkDefault false;
      };

      systemd-boot = let
        mirror-efi = pkgs.writeShellApplication {
          name = "mirror-efi";

          runtimeInputs = with pkgs; [
            libuuid
            rsync
            coreutils
          ];

          text = ''
            mount_mountpoint="${config.boot.loader.efi.efiSysMountPoint}"
            main_device="$(findmnt --noheadings --output source "$mount_mountpoint")"
            mnt_target="$(mktemp -d)"

            # Create a cleanup trap to ensure the temporary mount doesn't survive
            cleanup() {
              umount -q "$mnt_target" || true
              rm -r "$mnt_target"
            }

            trap cleanup EXIT

            # For each EFI-labeled device, mount it and clone the main device
            for device in $(blkid --output device --match-token LABEL=EFI); do
              # No need to copy to itself
              if [ "$device" == "$main_device" ]; then
                continue
              fi

              echo "Copying EFI to $device"

              mount "$device" "$mnt_target"
              rsync -a --delete "$mount_mountpoint/" "$mnt_target"
              umount "$mnt_target"
            done
          '';
        };
      in {
        # Need to run nixos-rebuild switch --install-bootloader the first time:
        # https://github.com/NixOS/nixpkgs/issues/201677
        enable = mkDefault true;
        configurationLimit = mkDefault 8;
        consoleMode = mkDefault "max";

        extraInstallCommands = "${mirror-efi}/bin/mirror-efi";
      };

      efi.canTouchEfiVariables = mkDefault true;
    };
  };
}