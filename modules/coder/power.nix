# Coder workspace-driven power management for offsite-backup.
#
# offsite-backup hosts the Coder workspace microvms (modules/coder/microvm-host.nix)
# but is normally powered off — all power control (IPMI + smart switch) lives on
# elserver in modules/offsite-backup.nix (turn-on.service / turn-off.service).
# This module, imported by elserver alongside coder/server.nix, ties that power
# state to workspace activity:
#
#   • Auto-on:  the workspace template (modules/coder/template/main.tf) has a
#     terraform `local-exec` provisioner that runs `systemctl start
#     turn-on.service` on elserver (as the `coder` user, authorised by the
#     polkit rule below) before SSHing into offsite-backup to build the VM.
#     It also writes a keepalive timestamp so the autostop timer below doesn't
#     power the host off while the first `nix build` is still running (no VM
#     is active yet during a build).
#
#   • Auto-off: coder-vm-autostop.timer polls offsite-backup over SSH every 2
#     minutes. When no `microvm@*.service` is active and no backup is running
#     for a grace period, it starts turn-off.service, which IPMI-softs the host
#     and cuts the smart switch — the same path the nightly backup uses.
#
# turn-off.service itself is made workspace-aware (in modules/offsite-backup.nix)
# so neither the nightly backup nor this autostop can power the host off while a
# workspace is running.
#
# Requires: modules/coder/server.nix (for the `coder` user + state dir) and
# modules/offsite-backup.nix (for turn-on/turn-off) — both imported by elserver.
{ config, lib, pkgs, ... }:
let
  cfg = config.coder.power;
in
{
  options.coder.power = {
    offsiteBackupHost = lib.mkOption {
      type = lib.types.str;
      default = "192.168.178.4";
      description = ''
        Address of offsite-backup that elserver uses to SSH in and check
        workspace state. Must match the host turn-on.service waits for (the
        `offsiteBackupHost` let binding in modules/offsite-backup.nix) and be
        reachable from elserver as root via SSH (the backup already uses this).
      '';
    };

    autostopGraceSeconds = lib.mkOption {
      type = lib.types.ints.positive;
      default = 600;
      description = ''
        How long offsite-backup must have no active workspace VMs (and no
        running backup) before the autostop timer powers it off. Prevents
        flapping when a user stops one workspace and starts another shortly
        after.
      '';
    };
  };

  config = lib.mkIf config.coder.server.enable {
    # Let the `coder` user (which runs the embedded terraform provisioner)
    # start turn-on.service. polkit authorises the D-Bus StartUnit call, so
    # this works even though the coder systemd service has NoNewPrivileges
    # (which would block a setuid sudo). The rule is scoped to exactly that
    # one unit + verb.
    security.polkit.enable = true;
    security.polkit.extraConfig = ''
      polkit.addRule(function(action, subject) {
        if (action.id === "org.freedesktop.systemd1.manage-units" &&
            action.lookup("unit") === "turn-on.service" &&
            action.lookup("verb") === "start" &&
            subject.user === "coder") {
          return polkit.Result.YES;
        }
      });
    '';

    # State dir written by the template's local-exec (as the `coder` user) and
    # read by the autostop service (as root). Lives under /var/lib/coder so the
    # coder service's StateDirectory/ProtectSystem=strict allow writes.
    systemd.tmpfiles.rules = [
      "d /var/lib/coder/vm-power 0755 coder coder -"
    ];

    systemd.services.coder-vm-autostop = {
      description = "Power off offsite-backup when no Coder workspaces are active";
      path = with pkgs; [
        openssh
        coreutils
        gawk
      ];
      serviceConfig = {
        Type = "oneshot";
        StateDirectory = "coder-vm-autostop";
        # Bounded by the SSH ConnectTimeout (~10s of work per run); turn-off is
        # started with --no-block so this service never waits on its 5-min
        # power-off sequence.
        RuntimeMaxSec = "120s";
      };
      # NB: bash `${var:-default}` is escaped as `''${...}` in Nix '' strings;
      # `${cfg.offsiteBackupHost}` / `${toString cfg.autostopGraceSeconds}` are
      # Nix interpolation. Plain `$var` / `$(...)` / `$((...))` are literal.
      script = ''
        set -u
        SSH_OPTS="-o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new"

        # Host already down? Nothing to do.
        if ! ssh $SSH_OPTS root@${cfg.offsiteBackupHost} true 2>/dev/null; then
          rm -f /var/lib/coder-vm-autostop/idle-since
          exit 0
        fi

        # Active microvm count + backup-active flag in one round trip. If the
        # SSH call itself fails, treat it as "unknown" and do nothing rather
        # than risk shutting down on a transient blip.
        count_line=$(ssh $SSH_OPTS root@${cfg.offsiteBackupHost} 'printf "%s %s\n" "$(systemctl list-units --type=service --state=active "microvm@*" --no-legend --no-pager 2>/dev/null | grep -c . || echo 0)" "$(systemctl is-active --quiet offsite-backup.service && echo yes || echo no)"' 2>/dev/null) || { rm -f /var/lib/coder-vm-autostop/idle-since; exit 0; }
        vms=$(printf '%s' "$count_line" | awk '{print $1}')
        backup=$(printf '%s' "$count_line" | awk '{print $2}')

        if [ "''${vms:-0}" -gt 0 ] || [ "''${backup:-no}" = "yes" ]; then
          rm -f /var/lib/coder-vm-autostop/idle-since
          exit 0
        fi

        # A workspace build may be in progress with no VM active yet — respect
        # the keepalive timestamp the template's local-exec wrote at launch.
        now=$(date +%s)
        if [ -f /var/lib/coder/vm-power/keepalive-until ]; then
          ka=$(cat /var/lib/coder/vm-power/keepalive-until 2>/dev/null || echo 0)
          if [ "$now" -lt "''${ka:-0}" ]; then
            rm -f /var/lib/coder-vm-autostop/idle-since
            exit 0
          fi
        fi

        # First idle sighting starts the clock; subsequent runs wait it out.
        if [ ! -f /var/lib/coder-vm-autostop/idle-since ]; then
          echo "$now" > /var/lib/coder-vm-autostop/idle-since
          exit 0
        fi
        idle_since=$(cat /var/lib/coder-vm-autostop/idle-since 2>/dev/null || echo 0)
        if [ "$((now - ''${idle_since:-0}))" -ge ${toString cfg.autostopGraceSeconds} ]; then
          rm -f /var/lib/coder-vm-autostop/idle-since
          /run/current-system/sw/bin/systemctl --no-block start turn-off.service
        fi
      '';
    };

    systemd.timers.coder-vm-autostop = {
      description = "Poll for idle Coder workspaces on offsite-backup";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "1min";
        OnUnitActiveSec = "2min";
        Unit = "coder-vm-autostop.service";
      };
    };
  };
}
