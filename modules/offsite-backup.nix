  {
  config,
  pkgs,
  ...
  } :
let
  offsiteBackupHost = "192.168.178.4";
  offsiteBackupHostIpmi = "192.168.178.5";
  smartSwitchHost = "192.168.178.7";
in
  {
  sops.templates."offsite-backup-on" = {
    mode = "700";
    content = ''
      #!/usr/bin/env bash
      set -euo pipefail
      echo "Turning on power outlet"
      curl "http://${smartSwitchHost}/cm?cmnd=Power%20ON"

      echo "Turning on power via IPMI"
      while ! ipmitool -H ${offsiteBackupHostIpmi} -U ${config.sops.placeholder.ipmi-username} -P ${config.sops.placeholder.ipmi-password} power on 2>&1; do
        echo "IPMI command failed, retrying"
        sleep 5
      done
      echo

      echo "Waiting for host..."
      while [ -z "$(socat -T2 stdout tcp:${offsiteBackupHost}:22,connect-timeout=2,readbytes=1 2>/dev/null)" ]; do
        echo "still waiting..."
        sleep 5
      done
      echo "up!"
    '';
  };

  sops.templates."offsite-backup-off" = {
    mode = "700";
    content = ''
      #!/usr/bin/env bash
      set -euo pipefail
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
  };

  systemd.targets.offsite-backup = {
    description = "Backup Job Target";
      bindsTo = [
        "turn-on.service"
        "offsite-backup.service"
        "turn-off.service"
      ];
  };

  systemd.services.turn-on = {
    path = with pkgs; [
      curl
      ipmitool
      bash
      socat
    ];
    description = "Turn on offsite-backup socket and server";
    partOf = [ "offsite-backup.target" ];
    before = [ "offsite-backup.service" ];
    wants = [
      "sops-nix.service"
    ];
    after = [
      "sops-nix.service"
    ];
    serviceConfig = {
      Type = "oneshot";
      TimeoutSec = 300;
      ExecStart = "${pkgs.bash}/bin/bash ${config.sops.templates."offsite-backup-on".path}";
    };
    restartIfChanged = false;
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
      zfs-autobackup -v --clear-mountpoint --destroy-missing 14d --no-holds --set-properties readonly=on --ssh-target ${offsiteBackupHost} offsite backup/proxmox
    '';
    serviceConfig = {
      Type = "oneshot";
    };
    restartIfChanged = false;

  };

  systemd.services.turn-off = {
    path = with pkgs; [
      curl
      ipmitool
      bash
    ];
    description = "Turn off backup socket";
    partOf = [ "offsite-backup.target" ];
    wants = [
      "sops-nix.service"
    ];
    after = [
      "offsite-backup.service"
      "sops-nix.service"
    ];
    serviceConfig = {
      Type = "oneshot";
      TimeoutSec = 300;
      ExecStart = "${pkgs.bash}/bin/bash ${config.sops.templates."offsite-backup-off".path}";
    };
    restartIfChanged = false;
  };
  systemd.services.offsite-backup-start = {
    description = "Kick off the offsite backup sequence";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "/run/current-system/sw/bin/systemctl start offsite-backup.target";
    };
  };

  systemd.timers.offsite-backup = {
    description = "Run the full offsite-backup sequence";
    wantedBy = [ "timers.target" ];
      wants = ["offsite-backup.target"];
    timerConfig = {
      OnCalendar = "daily";
      #          OnCalendar = "hourly";
      Persistent = true;
      Unit = "offsite-backup-start.service";
    };
    #      unitConfig = {
    #        Unit = "backup.target";
    #      };
  };
}
