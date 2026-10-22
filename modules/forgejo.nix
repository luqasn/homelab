{
  config,
  lib,
  pkgs,
  utils,
  ...
}:
let
  homelab = import ../lib {
    inherit config;
    inherit lib;
  };

  domain = config.common.internalDomain;
  forgejoDomain = "forgejo.${domain}";
  runnerInstanceName = "forgejo-local";
  # The token gets its own runtime directory (not inside /run/forgejo, which
  # systemd removes whenever the forgejo service restarts and is only
  # regenerated once per boot).
  runnerTokenDir = "forgejo-runner-token";
  runnerTokenFile = "/run/${runnerTokenDir}/token";
  # Keep the state directory used by the old gitea-actions-runner module, so
  # the existing `.runner` registration (uuid + runner token) survives the
  # migration and we do not have to register a duplicate runner.
  runnerStateDir = "/var/lib/gitea-runner/${runnerInstanceName}";
  runnerUnitName = "forgejo-runner-${utils.escapeSystemdPath runnerInstanceName}";
  runnerLabels = [ "native:host" ];
  runnerHostPackages = with pkgs; [
    bash
    # The nix CLI, so workflows (and composite actions that shell out to
    # `nix run`) can use it; the runner's default PATH has no nix.
    config.nix.package
    coreutils
    curl
    gawk
    git-filter-repo
    gitMinimal
    gnused
    nodejs
    wget
  ];
  # The labels from the config override the ones recorded in `.runner`, so
  # changes to runnerLabels do not require a new registration.
  runnerConfig = (pkgs.formats.yaml { }).generate "forgejo-runner-config.yaml" {
    runner.labels = runnerLabels;
  };
  # Forgejo repository (owner/name) whose Actions job queue the idle-gated
  # restart below observes. Matches the git origin of this repo.
  forgejoRepo = "luqasn/homelab";
in
{
  # The msmtp/SMTP password secret is group-readable by "sendmail", so the
  # forgejo user must be a member to let msmtp fetch the credentials.
  users.groups.sendmail.members = [
    "forgejo"
  ];

  # --- Forgejo service ---
  services.forgejo = {
    enable = true;
    database = {
      type = "postgres";
      host = "/var/run/postgresql";
      name = "forgejo";
      user = "forgejo";
    };
    settings = {
      server = {
        DOMAIN = domain;
        ROOT_URL = "https://${forgejoDomain}/";
        HTTP_ADDR = "/run/forgejo/forgejo.sock";
        PROTOCOL = "http+unix";
        SSH_PORT = lib.head config.services.openssh.ports;
      };
      service = {
        DISABLE_REGISTRATION = false;
      };
      # Send transactional mail (registration, notifications, ...) through the
      # host's system sendmail, i.e. the msmtp wrapper configured in
      # modules/homelab.nix, matching nextcloud and vaultwarden.
      mailer = {
        ENABLED = true;
        PROTOCOL = "sendmail";
        FROM = "server@romeromail.de";
        SENDMAIL_PATH = "${pkgs.system-sendmail}/bin/sendmail";
      };
      actions = {
        ENABLED = true;
        DEFAULT_ACTIONS_URL = "github";
      };
      log = {
        LEVEL = "Info";
      };
      cron = {
        ENABLE = true;
        RUN_AT_START = true;
        SCHEDULE = "@every 1h";
      };
    };
  };

  # --- Runner token generation ---
  # Wait for Forgejo to be up, then generate a runner token.
  systemd.services.forgejo-runner-token = {
    description = "Generate Forgejo runner registration token";
    after = [ "forgejo.service" ];
    wants = [ "forgejo.service" ];
    wantedBy = [ "multi-user.target" ];
    # The forgejo CLI refuses to run as root ("Forgejo is not supposed to be
    # run as root") and needs these to locate its app.ini and postgres
    # database. Run it as the forgejo user with the same environment the
    # forgejo service itself uses.
    environment = {
      USER = config.services.forgejo.user;
      HOME = config.services.forgejo.stateDir;
      FORGEJO_WORK_DIR = config.services.forgejo.stateDir;
      FORGEJO_CUSTOM = config.services.forgejo.customDir;
    };
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      User = config.services.forgejo.user;
      Group = config.services.forgejo.group;
      RuntimeDirectory = runnerTokenDir;
      UMask = "0077";
    };
    script = ''
      set -euo pipefail
      # Wait for the unix socket to be ready
      ready=""
      for i in $(seq 1 30); do
        if ${pkgs.netcat-openbsd}/bin/nc -z -U ${config.services.forgejo.settings.server.HTTP_ADDR} 2>/dev/null; then
          ready=1
          break
        fi
        echo "Waiting for Forgejo socket..."
        sleep 2
      done
      if [ -z "$ready" ]; then
        echo "Forgejo socket never became ready; giving up." >&2
        exit 1
      fi
      sleep 2
      TOKEN=$(${config.services.forgejo.package}/bin/forgejo actions generate-runner-token)
      echo -n "TOKEN=$TOKEN" > ${runnerTokenFile}
      chmod 600 ${runnerTokenFile}
    '';
  };

  # --- Forgejo self-hosted runner ---
  # nixpkgs' gitea-actions-runner module no longer accepts `forgejo-runner`,
  # and its replacement (`services.forgejo-runner`) wants a pre-registered
  # uuid + runner token instead of the registration token generated at boot.
  # Keep the registration-token flow with a small local service: forgejo-runner
  # still implements it, and reusing the old state directory preserves the
  # existing registration.
  #
  # The runner reaches Forgejo through the local nginx vhost because its HTTP
  # client has no unix-socket support ("http://unix:/run/forgejo/forgejo.sock"
  # would be parsed as the DNS host "unix").
  #
  # `restartIfChanged = false` is essential for self-deploys: the runner is what
  # executes this repo's Forgejo Actions jobs, including the deploy workflow that
  # runs `switch-to-configuration` on elserver. If a deploy changes this unit
  # (e.g. hostPackages), switch-to-configuration would normally stop the runner
  # mid-switch, which kills the deploy job itself. Skipping the restart lets the
  # job finish; the runner keeps running the previous generation until it is
  # restarted, which deploy-machines.yml schedules as a detached transient unit
  # after the deploy completes.
  systemd.services.${runnerUnitName} = {
    description = "Forgejo Actions runner (${runnerInstanceName})";
    wantedBy = [ "multi-user.target" ];
    after = [
      "forgejo-runner-token.service"
      "nginx.service"
    ];
    wants = [
      "forgejo-runner-token.service"
      "nginx.service"
    ];
    restartIfChanged = false;
    environment = {
      HOME = runnerStateDir;
      INSTANCE_DIR = runnerStateDir;
    };
    path = [ pkgs.coreutils ] ++ runnerHostPackages;
    serviceConfig = {
      DynamicUser = true;
      User = "gitea-runner";
      StateDirectory = [
        "gitea-runner"
        "gitea-runner/${runnerInstanceName}"
      ];
      WorkingDirectory = runnerStateDir;
      # DynamicUser can mount the executable directory noexec; host jobs need
      # to execute scripts from the runner state directory.
      ExecPaths = [ runnerStateDir ];
      Restart = "on-failure";
      RestartSec = 10;
      LoadCredential = [ "token:${runnerTokenFile}" ];
      ExecStartPre = pkgs.writeShellScript "forgejo-runner-register-${runnerInstanceName}" ''
        set -euo pipefail

        # Accept both the old systemd-style `TOKEN=...` file and a raw token.
        if grep -q -m1 -E '^[[:space:]]*TOKEN=' "$CREDENTIALS_DIRECTORY/token"; then
          token="$(sed -n -E 's/^[[:space:]]*TOKEN=//p' "$CREDENTIALS_DIRECTORY/token" | tail -n1)"
        else
          token="$(cat "$CREDENTIALS_DIRECTORY/token")"
        fi

        # Only register when there is no registration yet. The registration
        # token is regenerated at every boot, but the runner token inside
        # `.runner` stays valid, so re-registering on every boot would only
        # create duplicate runner entries (labels are refreshed from the
        # config on every daemon start anyway).
        if [ ! -e "$INSTANCE_DIR/.runner" ]; then
          ${lib.getExe pkgs.forgejo-runner} register --no-interactive \
            --instance ${lib.escapeShellArg "https://${forgejoDomain}"} \
            --token "$token" \
            --name ${lib.escapeShellArg runnerInstanceName} \
            --labels ${lib.escapeShellArg (lib.concatStringsSep "," runnerLabels)} \
            --config ${runnerConfig}
        fi
      '';
      ExecStart = "${lib.getExe pkgs.forgejo-runner} daemon --config ${runnerConfig}";
    };
  };

  # --- Idle-gated runner restart ---
  # The runner has to be restarted after a self-deploy to pick up the new
  # generation (hostPackages, binary, ...). A blind restart cancels whatever job
  # the capacity-1 runner is executing, and on a merge to main the tasks queued
  # behind the deploy (mirror-to-github, vuln-scan) are exactly that. Instead of
  # restarting on a timer, this unit waits until Forgejo reports no task left
  # waiting or running for the `native` label, then restarts the runner.
  #
  # It must run on the host, not as a step/job of the deploy workflow: with
  # capacity 1 the queued tasks cannot start while the deploy job is still
  # holding the runner, so a gate inside that job could never observe the queue
  # drain. deploy-machines.yml starts it with `systemctl --no-block start`, so
  # the step returns and the deploy job ends, freeing the runner for the queued
  # tasks; the unit is deliberately not wanted by any target, so it never runs
  # on boot.
  #
  # It authenticates with the existing Renovate bot PAT (config.sops.secrets.
  # renovate-token, `repo` scope) — the same bot whose token the workflows use
  # as CI_BOT_TOKEN — via the Gitea/Forgejo-compatible `actions/runners/jobs`
  # endpoint that runner autoscalers (e.g. KEDA) poll.
  systemd.services.forgejo-runner-restart-when-idle = {
    description = "Restart the Forgejo runner once no job is queued or running";
    after = [ "sops-nix.service" "network-online.target" ];
    wants = [ "network-online.target" ];
    path = [
      pkgs.bash
      pkgs.coreutils
      pkgs.curl
      pkgs.jq
      config.systemd.package
    ];
    serviceConfig = {
      Type = "oneshot";
      # The whole backlog (deploy + mirror + a vulnerability scan) can take
      # hours, and each job is capped at 3h.
      TimeoutStartSec = "12h";
    };
    # Never let switch-to-configuration touch this unit, exactly like the runner
    # itself above. switch-to-configuration-ng starts a changed unit and blocks
    # (`block_on_jobs`) until its start job finishes; for a oneshot that means
    # until ExecStart returns. This gate's ExecStart only returns once no
    # `native` task is queued or running — but a self-deploy is itself a
    # `native` task, so a restarted gate waits for the deploy that is restarting
    # it, forever. It then keeps holding
    # /run/nixos/switch-to-configuration.lock, so every later deploy fails at
    # `boot` with "Could not acquire lock" (exit 11). The workflow starts the
    # gate with `systemctl --no-block start`; that is the only start it needs.
    restartIfChanged = false;
    script = ''
      set -euo pipefail
      api="https://${forgejoDomain}/api/v1/repos/${forgejoRepo}"
      token="$(cat ${config.sops.secrets.renovate-token.path})"
      auth=(-H "Authorization: token $token")

      # Let the deploy job that started this unit finish, so its own task is not
      # part of what has to drain.
      sleep 15

      while :; do
        if jobs=$(curl -fsS "''${auth[@]}" "$api/actions/runners/jobs"); then
          # Filter client-side rather than with the `labels` query parameter: a
          # buggy/empty server-side filter would look like an empty queue and
          # restart the runner while a job is still running.
          active=$(jq '
            [ .[]
              | select((.status == "waiting" or .status == "running")
                       and ((.runs_on // []) | index("native")))
            ] | length
          ' <<<"$jobs")
        else
          echo "could not query the job queue (curl failed); retrying" >&2
          active=unknown
        fi

        if [ "$active" = 0 ]; then
          echo "no queued or running native task; restarting ${runnerUnitName}.service"
          systemctl restart "${runnerUnitName}.service"
          exit 0
        fi

        echo "runner still busy (active=$active); waiting for the queue to drain"
        sleep 10
      done
    '';
  };

  # --- Nginx reverse proxy ---
  services.nginx.virtualHosts.${forgejoDomain} = homelab.mkVirtualHost {
    port = null; # Using unix socket
    internal = true;
    settings = {
      proxyPass = "http://unix:${config.services.forgejo.settings.server.HTTP_ADDR}";
    };
  };
}
