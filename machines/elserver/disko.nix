{
  lib,
  clan-core,
  config,
  ...
}:
{
  options = {
    disko.secondStageKeyPath = lib.mkOption {
        default = null;
        type = with lib.types; nullOr path;
    };
  };
  config = {
    boot.loader.systemd-boot.enable = true;
    boot.loader.efi.canTouchEfiVariables = true;
    disko.devices = {
      disk = {
        "main" = {
          # suffix is to prevent disk name collisions
          name = "main-elserver";
          type = "disk";
          # Set the following in flake.nix for each maschine:
          # device = <uuid>;
          content = {
            type = "gpt";
            partitions = {
            ESP = {
              size = "1024M";
              type = "EF00";
              content = {
                type = "filesystem";
                format = "vfat";
                mountpoint = "/boot";
                mountOptions = [ "umask=0077" ];
              };
            };
              "root" = {
                size = "100%";
                content = {
                  type = "zfs";
                  pool = "zroot";
                };
              };
            };
          };
        };
      };

      zpool = {
        zroot = {
          type = "zpool";
          rootFsOptions =
            {
              acltype = "posixacl";
              atime = "off";
              compression = "zstd";
              mountpoint = "none";
              xattr = "sa";
              encryption = "aes-256-gcm";
              keyformat = "passphrase";
              keylocation = "file://${config.disko.secondStageKeyPath}";
            };
                  postCreateHook = ''
                    zfs set keylocation=prompt zroot;
                  '';
          options.ashift = "12";
          options.cachefile = "none";

          datasets = {
            "local" = {
              type = "zfs_fs";
              options.mountpoint = "none";
            };
            "local/home" = {
              type = "zfs_fs";
              mountpoint = "/home";
              # Used by services.zfs.autoSnapshot options.
              options."autobackup:offsite" = "true";
            };
            "local/nix" = {
              type = "zfs_fs";
              mountpoint = "/nix";
              options."autobackup:offsite" = "false";
            };
            "local/persist" = {
              type = "zfs_fs";
              mountpoint = "/persist";
              options."autobackup:offsite" = "false";
              postMountHook = lib.optionalString (config.disko.secondStageKeyPath != null) ''
                cp ${config.disko.secondStageKeyPath} ${config.disko.rootMountPoint}/persist/.info
              '';
            };
            "local/lib" = {
              type = "zfs_fs";
              mountpoint = "/var/lib";
              options."autobackup:offsite" = "true";
            };
            "local/root" = {
              type = "zfs_fs";
              mountpoint = "/";
              options."autobackup:offsite" = "false";
              postCreateHook = "zfs snapshot zroot/local/root@blank";
            };
            "reserved" = {
              options = {
                mountpoint = "none";
                reservation = "100G";
              };
              type = "zfs_fs";
            };
          };
        };
      };
    };
  };
}
