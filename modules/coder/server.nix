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
{ config, lib, pkgs, self, inputs, ... }:
let
  cfg = config.coder.server;
  utils = import ../../lib { inherit config lib; };
  templateDir = "${self}/modules/coder/template";
  provisionerKey = config.clan.core.vars.generators.coder-provisioner-key;
  # `nixpkgs-coder` (a dedicated nixos-unstable flake input; see flake.nix) is
  # the single source of truth for the Coder version run by BOTH the server 
  # and every workspace agent. The server imports its `coder` directly from
  # this input (`coderSrc`, below); the revision of this same input
  # (`sourceInfo.rev`) is passed to the workspace template as the
  # `coder_nixpkgs_rev` terraform variable, where the per-workspace flake pins
  # a second `nixpkgs-coder` input to that rev and overlays its `coder` in. So
  # server and agent are always byte-for-byte on the SAME coder revision — 
  # the version-matching invariant; mismatches make the agent refuse the
  # server's RPC API version ("server is at version X, behind requested minor
  # version Y"). This input tracks nixos-unstable (newer `coder` than the
  # homelab's pinned nixpkgs); bump it with `nix flake lock
  # --update-input nixpkgs-coder` (or `nix flake update nixpkgs-coder` on
  # newer Nix).
  #
  # Imported with `allowUnfree = true` because `coder`'s build input
  # `terraform` is unfree (bsl11) in nixpkgs; the host's own
  # `nixpkgs.config.allowUnfree` (set in machines/elserver) does not propagate
  # to this separate import. `coder` is a prebuilt Go binary (fetchurl,
  # stdenvNoCC), so pulling it across nixpkgs revisions is ABI-safe.
  coderSrc = import inputs.nixpkgs-coder {
    system = pkgs.stdenv.hostPlatform.system;
    config.allowUnfree = true;
  };
  nixpkgsRev = inputs.nixpkgs-coder.sourceInfo.rev;
in
{
  imports = [ ./provisioner-key.nix ];

  options.coder.server = {
    enable = lib.mkEnableOption "Coder server (web UI + provisioner)";

    package = lib.mkOption {
      type = lib.types.package;
      default = coderSrc.coder;
      defaultText = lib.literalExpression "inputs.nixpkgs-coder.coder";
      description = ''
        Coder package to use (provides both the CLI and `coder server`).
        Defaults to the `coder` attr of the `nixpkgs-coder` flake input
        (nixos-unstable), so the server tracks a current coder — NOT the
        homelab's pinned `pkgs.coder` (which lags). Bump the version by updating
        the `nixpkgs-coder` input (`nix flake lock --update-input nixpkgs-coder`);
        the workspace agent follows automatically via `coder_nixpkgs_rev`.
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

    # `coder` CLI for `coder login` / day-to-day admin, plus the template
    # push wrapper below. Run `coder login ${cfg.accessUrl}` first.
    environment.systemPackages = [
      cfg.package
      (pkgs.writeShellScriptBin "coder-push-microvm-template" ''
        set -euo pipefail
        : "''${CODER_VM_HOST:=offsite-backup}"
        exec ${lib.getExe' cfg.package "coder"} templates push microvm-nixos \
          --directory "${templateDir}" \
          --var host_ssh_address="''${CODER_VM_HOST}" \
          --var host_ssh_user=root \
          --var host_ssh_private_key_path="${provisionerKey.files."id_ed25519".path}" \
          --var bridge_name=${cfg.bridgeName} \
          --var bridge_subnet=${cfg.bridgeSubnet} \
          --var coder_server_ip=${config.common.internalIp} \
          --var coder_server_hostname=${cfg.domain} \
          --var coder_nixpkgs_rev=${nixpkgsRev} \
          --var authorized_ssh_keys='${lib.concatStringsSep "\n" cfg.authorizedSshKeys}' \
          "$@"
      '')
    ];
  };
}
