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
  # nixpkgs' gitea-actions-runner instance module names its systemd unit
  # "gitea-runner-${escapeSystemdPath <instance-name>}", i.e. the instance
  # "forgejo-local" becomes the unit "gitea-runner-forgejo\x2dlocal.service".
  # Derive the name the same way here, so the override below hits the
  # generated unit instead of creating a second, empty one (which systemd
  # refuses to start: "Service has no ExecStart=").
  runnerUnitName = "gitea-runner-${utils.escapeSystemdPath runnerInstanceName}";
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

  # --- Forgejo self-hosted runner ---
  services.gitea-actions-runner = {
    package = pkgs.forgejo-runner;
    instances.${runnerInstanceName} = {
      enable = true;
      name = "forgejo-local";
      # forgejo-runner speaks plain HTTP(S) only: its HTTP client has no
      # unix-socket support, so "http://unix:/run/forgejo/forgejo.sock" is
      # parsed as the DNS host "unix" and registration fails
      # ("Cannot ping the Forgejo instance server: lookup unix: no such
      # host"). Point it at the local nginx vhost that fronts the unix
      # socket instead.
      url = "https://${forgejoDomain}";
      tokenFile = runnerTokenFile;
      labels = [
        "native:host"
      ];
      hostPackages = with pkgs; [
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

  # Ensure the runner waits for token generation, and for nginx (the runner
  # reaches forgejo through the https vhost nginx terminates).
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
    after = [
      "forgejo-runner-token.service"
      "nginx.service"
    ];
    wants = [
      "forgejo-runner-token.service"
      "nginx.service"
    ];
    restartIfChanged = false;
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
