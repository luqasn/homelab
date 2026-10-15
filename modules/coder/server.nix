# Coder server module — runs on the machine that hosts the Coder web UI and
# the embedded provisioner (here: `elserver`).
#
# The server:
#   • stores its state in the existing local PostgreSQL (modules/homelab.nix)
#     using peer authentication over the unix socket — no password needed,
#     the `coder` system user maps to the `coder` DB role via the
#     `superuser_map` ident map defined there;
#   • listens on a loopback HTTP port fronted by nginx (TLS via the existing
#     `*.${common.domain}` ACME cert);
#   • exposes the workspace template files at /etc/coder/templates/microvm-nixos
#     and a `coder-push-microvm-template` wrapper that uploads them with the
#     right variables;
#   • generates a provisioner SSH keypair (clan var `coder-provisioner-key`)
#     used to SSH into the microvm host (offsite-backup) as root when
#     creating/stopping workspaces.
#
# See modules/coder/README.md for the full deploy walkthrough.
{ config, lib, pkgs, self, ... }:
let
  cfg = config.coder.server;
  utils = import ../../lib { inherit config lib; };
  templateDir = "${self}/modules/coder/template";
  provisionerKey = config.clan.core.vars.generators.coder-provisioner-key;
  # Content-addressed copy of the template directory. Its store path changes
  # ONLY when the template's own files change (unlike `${self}`, which changes
  # on every commit), so it is the service's "did the template change?" key:
  # the service records the last pushed revision and is a no-op when it matches.
  templateRev = builtins.path {
    path = ./template;
    name = "coder-microvm-template";
  };
  # Uploads the workspace template with the right variables. Installed on PATH
  # for interactive use and run by coder-push-template.service with `--yes`.
  # It authenticates with the `coder login` session (long-lived thanks to
  # CODER_DEFAULT_TOKEN_LIFETIME below) or an explicit CODER_SESSION_TOKEN.
  pushTemplate = pkgs.writeShellScriptBin "coder-push-microvm-template" ''
    set -euo pipefail
    : "''${CODER_VM_HOST:=offsite-backup}"
    # Pin the server under test: a stored `coder login` may point at a
    # different instance.
    : "''${CODER_URL:=${cfg.accessUrl}}"
    export CODER_URL
    # A deploy that bumps the Coder version restarts coder.service, so wait for
    # the API to answer before pushing instead of racing the server's startup
    # and DB migrations. Probe through the access URL (same path the push uses)
    # so the Host/TLS checks match. 30 attempts * 2s = 60s max.
    for ((i = 0; i < 30; i++)); do
      ${pkgs.curl}/bin/curl -fsS -o /dev/null "${cfg.accessUrl}/healthz" && break
      sleep 2
    done
    exec ${lib.getExe' cfg.package "coder"} templates push microvm-nixos \
      --directory "${templateDir}" \
      --var host_ssh_address="''${CODER_VM_HOST}" \
      --var host_ssh_user=root \
      --var host_ssh_private_key_path="${provisionerKey.files."id_ed25519".path}" \
      --var bridge_name=${cfg.bridgeName} \
      --var bridge_subnet=${cfg.bridgeSubnet} \
      --var coder_server_ip=${config.common.internalIp} \
      --var coder_server_hostname=${cfg.domain} \
      --var authorized_ssh_keys='${lib.concatStringsSep "\n" cfg.authorizedSshKeys}' \
      "$@"
  '';
  # `coder` is pinned to a fixed upstream GitHub release by a small overlay
  # (modules/coder/template/coder-overlay.nix). That file is the single source
  # of truth for BOTH the server and every workspace agent: the server applies
  # it over the host's `pkgs` here, and the workspace template writes/imports
  # the same overlay, so server and agent always run the same Coder version
  # (the version-matching invariant — mismatches make the agent refuse the
  # server's RPC API version: "server is at version X, behind requested minor
  # version Y"). Bump Coder by editing that overlay, then redeploy elserver
  # and re-push the workspace template.
  #
  # The host's `nixpkgs.config.allowUnfree` (set in machines/elserver) covers
  # `coder`'s `terraform` build input, so no separate nixpkgs import is needed.
  coderOverlay = import ./template/coder-overlay.nix;
  coderPkgs = pkgs.extend coderOverlay;
in
{
  imports = [ ./provisioner-key.nix ];

  options.coder.server = {
    enable = lib.mkEnableOption "Coder server (web UI + provisioner)";

    package = lib.mkOption {
      type = lib.types.package;
      default = coderPkgs.coder;
      defaultText = lib.literalExpression "pkgs.coder (via modules/coder/template/coder-overlay.nix)";
      description = ''
        Coder package to use (provides both the CLI and `coder server`).
        Defaults to the pinned upstream release from
        `modules/coder/template/coder-overlay.nix` (an overlay over
        `pkgs.coder`) — NOT the homelab's pinned `pkgs.coder`, which lags.
        Bump Coder by editing that overlay's `version`/hashes, then redeploy
        elserver and re-push the workspace template; the agent follows via the
        same overlay.
      '';
    };

    domain = lib.mkOption {
      type = lib.types.str;
      default = "coder.${config.common.internalDomain}";
      description = "Public virtual host domain served by nginx.";
    };

    accessUrl = lib.mkOption {
      type = lib.types.str;
      default = "https://${cfg.domain}";
      description = ''
        External URL the Coder agent inside a workspace VM uses to phone home.
        Must be reachable from inside the VMs — they NAT out through whichever
        microvm host they run on (offsite-backup or elserver; elserver-hosted
        VMs reach elserver directly on the LAN, offsite-backup-hosted ones go
        via the site-to-site VPN), so this must resolve to `elserver` from the
        public internet (or via Tailscale if you reconfigure it).
      '';
    };

    wildcardDomain = lib.mkOption {
      type = lib.types.str;
      default = "coder.${config.common.internalDomain}";
      defaultText = lib.literalExpression "\"coder.\${config.common.internalDomain}\"";
      description = ''
        Hostname whose wildcard (`*.<wildcardDomain>`) Coder serves
        subdomain-based workspace apps from. Maps to
        `CODER_WILDCARD_ACCESS_URL = "*.<wildcardDomain>"``, so app URLs are
        `<app-subdomain>.<wildcardDomain>` (e.g.
        `8080--main--ws--owner.coder.<internalDomain>`).

        Defaults to `coder.<internalDomain>` — the SAME host as the dashboard
        (`coder.server.domain`) — so apps live one label BELOW the dashboard
        (`<app>.coder.<internalDomain>`), i.e. the wildcard is a child of the
        access URL host. This is Coder's canonical topology
        (`*.coder.example.com` under `coder.example.com`): the dashboard host
        `coder.<internalDomain>` is covered by the existing `*.<internalDomain>`
        ACME SAN, and the app wildcard `*.coder.<internalDomain>` gets its own
        SAN (see modules/homelab.nix). Keep the wildcard a child of the access
        URL host — never a bare top-level/public-suffix domain (Coder's docs
        warn browsers refuse Coder's cookies then) and avoid a sibling zone
        (e.g. `*.dev.<internalDomain>`) which needs its own cert and is off the
        supported path.

        Must satisfy:
          • the homelab ACME cert covers `*.<wildcardDomain>` (see the
            `extraDomainNames` SAN added in modules/homelab.nix),
          • nginx serves `*.<wildcardDomain>` (the serverAlias on the Coder
            vhost below),
          • DNS resolves `*.<wildcardDomain>` to this host (modules/adguard.nix
            adds a split-horizon rewrite for LAN clients; remote clients need a
            public DNS record).
      '';
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 7080;
      description = "Local HTTP port the Coder server binds on (nginx fronts it with TLS).";
    };

    prometheusPort = lib.mkOption {
      type = lib.types.port;
      default = 2112;
      description = "Port for Coder's Prometheus metrics endpoint (CODER_PROMETHEUS_ADDRESS).";
    };

    dataDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/coder";
      description = "State directory for the Coder server (HOME, cache, provisioner state).";
    };

    bridgeName = lib.mkOption {
      type = lib.types.str;
      default = "microbr0";
      description = "Bridge name on the microvm host. Passed to the workspace template.";
    };

    bridgeSubnet = lib.mkOption {
      type = lib.types.str;
      default = "192.168.100";
      description = "First three octets of the workspace subnet. Passed to the workspace template.";
    };

    authorizedSshKeys = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        # The same homelab key authorised on the homelab hosts' root accounts
        # (machines/{elserver,offsite-backup}/configuration.nix) — kept here as
        # the default so a freshly pushed template lets you SSH into a
        # workspace by jumping through the microvm host with your existing key.
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIR8NsEuDEGCRn1vm6Tcn5D5RhAqy/tRxkyE4kX6WUv/ homelab"
      ];
      description = ''
        SSH public keys authorised to log into workspace VMs (as the workspace
        user) deployed from the Coder microvm template. The
        `coder-push-microvm-template` wrapper joins these with newlines and
        passes them to the template as the `authorized_ssh_keys` terraform
        variable, which the per-workspace flake adds to the workspace user's
        `openssh.authorizedKeys.keys`. Defaults to the homelab key.

        Keys must not contain single quotes (standard for SSH public keys —
        base64 never produces one); the wrapper single-quotes the joined value
        when handing it to `coder templates push --var`.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # The `coder` user/group are created by provisioner-key.nix (shared with
    # offsite-backup). Add the home directory for the server's state dir here.
    users.users.coder.home = cfg.dataDir;

    # PostgreSQL database for Coder. Peer auth over the local socket: the
    # `coder` system user maps to the `coder` DB role via `superuser_map`
    # (modules/homelab.nix), so no password is required. ensureUsers /
    # ensureDatabases are list options, so this merges with the databases
    # already declared in modules/homelab.nix.
    services.postgresql = {
      ensureDatabases = [ "coder" ];
      ensureUsers = [
        { name = "coder"; ensureDBOwnership = true; }
      ];
    };

    systemd.services.coder = {
      description = "Coder server (workspaces web UI + embedded provisioner)";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" "postgresql.service" ];
      wants = [ "network-online.target" ];
      requires = [ "postgresql.service" ];
      # `openssh` for any `coder ssh`/scp helper invocations; terraform is
      # fetched on demand by Coder into its cache dir.
      path = [ pkgs.openssh ];
      environment = {
        CODER_ACCESS_URL = cfg.accessUrl;
        # Subdomain-based workspace apps + dashboard port-forwarding. Must be a
        # bare wildcard hostname (no scheme); scheme is taken from
        # CODER_ACCESS_URL. See wildcardDomain above + the nginx serverAlias.
        CODER_WILDCARD_ACCESS_URL = "*.${cfg.wildcardDomain}";
        # Path-based workspace apps are disabled for security now that the
        # wildcard access URL is configured: path apps can make requests to the
        # Coder API from workspace-served JS, so subdomain isolation is safer
        # (see docs/reference/cli/server.md --disable-path-apps). All template
        # apps use `subdomain = true`; the `external = true` ssh app is unaffected
        # (it's opened client-side, not proxied on a path).
        CODER_DISABLE_PATH_APPS = "true";
        # `coder login` sessions and API tokens default to 168h and are only
        # extended by activity, which is why the manual `echo yes |
        # coder-push-microvm-template` eventually failed with "your session has
        # expired". Raise both the default and the cap to effectively no
        # expiry, so the CLI session used by coder-push-template.service (and
        # by hand) stays valid. This applies to CLI/IDE API tokens, not web
        # session cookies (CODER_SESSION_DURATION).
        CODER_DEFAULT_TOKEN_LIFETIME = "876000h";
        CODER_MAX_TOKEN_LIFETIME = "876600h";
        CODER_HTTP_ADDRESS = "127.0.0.1:${toString cfg.port}";
        CODER_PG_CONNECTION_URL = "postgresql:///coder?host=/run/postgresql&user=coder";
        CODER_PROMETHEUS_ENABLE = "true";
        CODER_PROMETHEUS_ADDRESS = "127.0.0.1:${toString cfg.prometheusPort}";
        HOME = cfg.dataDir;
      };
      serviceConfig = {
        Type = "simple";
        User = "coder";
        Group = "coder";
        ExecStart = "${lib.getExe' cfg.package "coder"} server";
        WorkingDirectory = cfg.dataDir;
        StateDirectory = "coder";
        RuntimeDirectory = "coder";
        Restart = "on-failure";
        RestartSec = "5s";
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
      };
    };

    # TLS-terminate at nginx; Coder uses websockets heavily (agent connections,
    # terminals), so keep them upgraded and avoid idle timeouts dropping agents.
    # The same server block also serves the wildcard app zone
    # (*.<wildcardDomain>) as a serverAlias — Coder routes subdomain apps by
    # the Host header, so that MUST be forwarded verbatim (`Host $host`).
    # nginx drops http-level `proxy_set_header` inheritance the moment a
    # location defines any; `proxyWebsockets` emits Upgrade/Connection at the
    # location, so we re-state Host + the X-Forwarded-* here. Mirrors Coder's
    # documented nginx example (docs/tutorials/reverse-proxy-nginx.md).
    services.nginx.virtualHosts."${cfg.domain}" = utils.mkVirtualHost {
      port = cfg.port;
      internal = true;
      settings = {
        proxyWebsockets = true;
#        extraConfig = ''
#          # Forward the real Host so Coder can route subdomain-based apps
#          # (the http-level proxy_set_header is dropped at this location).
#          proxy_set_header Host $host;
#          proxy_set_header X-Real-IP $remote_addr;
#          proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
#          proxy_set_header X-Forwarded-Proto $scheme;
#          proxy_set_header X-Forwarded-Host $host;
#          proxy_read_timeout 3600s;
#          proxy_send_timeout 3600s;
#        '';
      };
    } // {
      # Serve the wildcard app zone from this server block too. Covered by the
      # homelab cert (*.coder.<internalDomain> SAN, modules/homelab.nix) and
      # resolved to this host by modules/adguard.nix (LAN) / public DNS.
      serverAliases = [ "*.${cfg.wildcardDomain}" ];
    };

    # Coder serves Prometheus metrics on a *separate* address
    # (CODER_PROMETHEUS_ADDRESS, not the primary HTTP port). Only has effect
    # where Prometheus runs (elserver imports modules/monitoring.nix).
    services.prometheus.scrapeConfigs = [
      {
        job_name = "coder";
        metrics_path = "/metrics";
        static_configs = [ { targets = [ "127.0.0.1:${toString cfg.prometheusPort}" ]; } ];
      }
    ];

    # Expose the workspace template on the server so an admin can push it
    # without a repo checkout:
    #   coder templates push microvm-nixos --directory /etc/coder/templates/microvm-nixos ...
    environment.etc."coder/templates/microvm-nixos".source = templateDir;

    # Push the workspace template whenever the deployed template changes. This
    # is what keeps the server and every workspace agent on the same Coder
    # version. The unit is started by the deploy workflow (it is deliberately
    # not wanted by any target, so it does not run on boot), and it records the
    # last pushed template revision so an unchanged template is a no-op.
    systemd.services.coder-push-template = {
      description = "Push the Coder microvm workspace template";
      after = [ "coder.service" "network-online.target" ];
      wants = [ "network-online.target" ];
      requires = [ "coder.service" ];
      environment = {
        TEMPLATE_REV = "${templateRev}";
        CODER_URL = cfg.accessUrl;
        # The service runs as root; systemd does not set HOME, and the `coder`
        # CLI looks for its session under $HOME/.config/coderv2.
        HOME = "/root";
      };
      serviceConfig = {
        Type = "oneshot";
        StateDirectory = "coder-push-template";
        # The push runs terraform init/plan; a cold cache can take a while.
        TimeoutStartSec = "15min";
      };
      script = ''
        set -euo pipefail
        # Wait for the API to answer (coder.service may have just restarted for
        # a version bump) and skip if nobody is logged in, so a fresh host does
        # not fail the deploy. Log in once as root on elserver and the next
        # deploy pushes.
        logged_in=0
        for ((i = 0; i < 30; i++)); do
          if ${lib.getExe' cfg.package "coder"} whoami >/dev/null 2>&1; then
            logged_in=1
            break
          fi
          sleep 2
        done
        if [ "$logged_in" -ne 1 ]; then
          echo "root is not logged in to Coder (or the API did not answer); skipping the template push. Run 'coder login ${cfg.accessUrl}' on elserver." >&2
          exit 0
        fi
        stamp="$STATE_DIRECTORY/template-rev"
        if [ -f "$stamp" ] && [ "$(cat "$stamp")" = "$TEMPLATE_REV" ]; then
          echo "microvm-nixos template already pushed for $TEMPLATE_REV"
          exit 0
        fi
        ${lib.getExe pushTemplate} --yes
        printf '%s\n' "$TEMPLATE_REV" > "$stamp"
      '';
    };

    # `coder` CLI for `coder login` / day-to-day admin, plus the template
    # push wrapper. The wrapper always targets ${cfg.accessUrl} (override with
    # CODER_URL) and authenticates with the stored `coder login` session (or an
    # explicit CODER_SESSION_TOKEN); coder-push-template.service drives it.
    # The session is long-lived because CODER_DEFAULT_TOKEN_LIFETIME is raised
    # above.
    environment.systemPackages = [
      cfg.package
      pushTemplate
    ];
  };
}
