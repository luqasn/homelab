  {
  config,
  pkgs,
  ...
  } :
let
  offsiteBackupHost = "192.168.178.4";
  offsiteBackupHostIpmi = "192.168.178.5";
  smartSwitchHost = "192.168.178.7";

  # Metric/label names verified against pdf/zfs_exporter v2.3.11 (the
  # prometheus-zfs-exporter package): snapshot creation time is exposed as
  #   zfs_dataset_creation_timestamp{name="<pool/dataset>@<snap>",pool="...",type="snapshot"}
  # when the `dataset-snapshot` collector is enabled and `creation` is added
  # to its property set (done in monitoring.nix). zfs-autobackup's `offsite`
  # plan names snapshots `offsite-...`, so `name=~"@offsite-.*"` selects them.
  # zfs exporter port (offsite-backup listens on 0.0.0.0, same default port):
  #   curl -s <offsiteBackupHost>:9134/metrics | grep -iE 'zfs_dataset_creation_timestamp'
in
  {
  # This module is imported by elserver only. Tell monitoring.nix (imported by
  # both elserver and offsite-backup) to scrape offsite-backup's zfs exporter
  # from elserver's Prometheus, so the scrape config lives next to the others
  # and is not duplicated on offsite-backup itself.
  monitoring.scrapeOffsiteBackup = offsiteBackupHost;

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

      # Keep offsite-backup up for 5 minutes after the replication finishes so
      # elserver's Prometheus can scrape its zfs exporter at the default 60s
      # interval before the host powers off (turn-off.service runs only after
      # this service completes, since it's ordered `before turn-off.service`).
      # The scrape carries the freshly-replicated snapshot timestamps, which
      # the freshness rules retain via last_over_time(...[48h]) while it's off.
      echo "backup done; sleeping 5m so Prometheus can scrape offsite-backup's zfs exporter"
      sleep 300
    '';
    serviceConfig = {
      Type = "oneshot";
      # 5m scrape window plus replication headroom. The default 90s would kill
      # the sleep before Prometheus finishes scraping.
      TimeoutSec = 600;
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

  # ------------------------------------------------------------------
  # Prometheus monitoring: how up-to-date are the offsite backups?
  #
  # No capture script: offsite-backup's zfs exporter (snapshot collector
  # enabled in monitoring.nix, listenAddress widened in its machine config)
  # is scraped directly by elserver's Prometheus. Both elserver and
  # offsite-backup expose per-snapshot creation timestamps natively, so
  # source/target freshness and lag are pure PromQL over the two scrape
  # jobs. Aggregate (no per-dataset labels) per request.
  #
  # offsite-backup is powered off ~23h/day, so its scrape is down most of the
  # time -- that's expected. `last_over_time(...[48h])` retains the last
  # scraped freshness value for 48h so age/stale alerts keep working while
  # it's off, and a separate alert covers "not scraped successfully in 48h".
  #
  # The scrape config itself lives in monitoring.nix (gated by
  # `monitoring.scrapeOffsiteBackup`, set above) so it sits with the others
  # and is not duplicated on offsite-backup.
  # ------------------------------------------------------------------

  services.prometheus.rules = [
    (builtins.toJSON {
      groups = [
        {
          name = "offsite-backup";
          rules = [
            # Newest offsite-... snapshot per dataset on offsite-backup. The
            # real metric from pdf/zfs_exporter is `zfs_dataset_creation_timestamp`
            # with labels name/pool/type; snapshot `name` looks like
            # `pool/dataset@offsite-...`, so the dataset is the part before `@`.
            # zfs-autobackup replicates elserver's source datasets under
            # `backup/proxmox/`, so a replicated snapshot's `name` is
            # `backup/proxmox/<source>@offsite-...`. A single `label_replace`
            # captures `<source>` (stripping both the replication prefix and the
            # `@offsite-...` suffix) into a new `dataset` label, so it matches
            # elserver's source path (e.g. `ssd/data/postgres`) and the lag join
            # lines up per dataset. `max by (dataset)` then keeps the newest
            # creation per dataset. `last_over_time` keeps the last good value
            # for 48h while the host is powered off, so the age alert keeps
            # counting up instead of going stale.
            #
            # The `name=~"backup/proxmox/.*@offsite-.*"` selector restricts to
            # replicated snapshots; non-replicated offsite snapshots (orphans)
            # are intentionally excluded from this metric.
            {
              record = "offsite_backup_last_snapshot_timestamp_seconds";
              expr = ''
                max by (dataset) (
                  label_replace(
                    last_over_time(zfs_dataset_creation_timestamp{job="offsite-backup-zfs",type="snapshot"}[48h]),
                    "dataset", "$1", "name", "([^@]*)@.*"
                  )
                )
              '';
            }
            {
              record = "offsite_backup_last_snapshot_age_seconds";
              expr = ''time() - offsite_backup_last_snapshot_timestamp_seconds'';
            }
            # Newest offsite-... snapshot per dataset on elserver (native local
            # `zfs` job). Same dataset-label extraction as above. Used as the
            # source-side reference for per-dataset lag.
            {
              record = "offsite_backup_source_last_snapshot_timestamp_seconds";
              expr = ''
                max by (dataset) (
                  label_replace(
                    zfs_dataset_creation_timestamp{job="zfs",type="snapshot"},
                    "dataset", "$1", "name", "([^@]*)@.*"
                  )
                )
              '';
            }
            # Per-dataset replication lag = newest elserver offsite snapshot
            # minus newest offsite-backup offsite snapshot, joined on the
            # `dataset` label. Both recording rules expose the elserver *source*
            # path as `dataset` (the target-side rule strips the `backup/proxmox/`
            # replication prefix), so the join matches per dataset.
            {
              record = "offsite_backup_lag_seconds";
              expr = ''offsite_backup_source_last_snapshot_timestamp_seconds - label_replace(offsite_backup_last_snapshot_timestamp_seconds{dataset=~"backup/proxmox/.*"}, "dataset", "$1", "dataset", "backup/proxmox/(.*)")'';
            }

            # offsite-backup hasn't been scraped successfully in 48h (i.e. the
            # backup window hasn't run / host can't be reached). up is always
            # present (0 while down), so min_over_time==0 means no success.
            {
              alert = "OffsiteBackupUnreachable";
              expr = ''min_over_time(up{job="offsite-backup-zfs"}[48h]) == 0'';
              for = "10m";
              labels.severity = "warning";
              annotations.summary = "offsite-backup has not been scraped successfully in 48h";
            }
            {
              alert = "OffsiteBackupStale";
              expr = ''offsite_backup_last_snapshot_age_seconds > 48 * 3600'';
              for = "10m";
              labels.severity = "warning";
              annotations.summary = "Offsite backup of dataset {{ $labels.dataset }} is older than 48h";
            }
            {
              alert = "OffsiteBackupLagging";
              expr = ''offsite_backup_lag_seconds > 24 * 3600'';
              for = "10m";
              labels.severity = "warning";
              annotations.summary = "Offsite backup of dataset {{ $labels.dataset }} is lagging behind elserver by >24h";
            }
          ];
        }
      ];
    })
  ];

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
