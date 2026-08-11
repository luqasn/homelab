# Microvm.nix host module — runs on the machine that hosts the Coder workspace
# VMs (here: `offsite-backup`).
#
# Adapted from the reference plan in `coder-experiment/nixos-module.nix`:
#   • the microvm.nix HOST module (imported below) already sets
#     `networking.useNetworkd = true` and `systemd.network.enable = true`, so
#     the whole host — uplink included — runs systemd-networkd; NixOS translates
#     the scripted `networking.interfaces.eno1.useDHCP` in
#     machines/*/configuration.nix into networkd units (`40-eno1`, `40-eno2`).
#   • Previously this module defined the bridge with the SCRIPTED
#     `networking.bridges`/`networking.interfaces` helpers, which NixOS then
#     translated into a `40-microbr0` netdev/network — the bridge and its
#     192.168.100.1/24 gateway DID come up — but the `cdr*` workspace TAPs had
#     no `.network` of their own and fell through to networkd's catch-all
#     `99-ethernet-default-dhcp`, being treated as routable DHCP links instead
#     of dumb bridge ports (racing the old `ip ... master microbr0` udev rule).
#     Outbound VM traffic never made it past the gateway: raw TCP to
#     1.1.1.1/8.8.8.8:53, :443 and GitHub:22 timed out. The fix below gives the
#     TAPs their OWN `20-…-taps` `.network` (`Bridge=microbr0`, no DHCP), which
#     sorts ahead of `99-…` and makes them plain bridge ports, and creates the
#     bridge directly as networkd `10-…` units (no scripted translation).
#   • `networking.nat` is independent of the network manager and works even with
#     the firewall disabled (modules/homelab.nix disables it) via its
#     standalone nat.service; on current NixOS it programs nftables directly.
#   • the workspace template keeps `type = "tap"` interfaces (cloud-hypervisor,
#     the template default, does not support `type = "bridge"`), so the host is
#     responsible for attaching the `cdr*` TAPs to the bridge — now done by the
#     networkd `Bridge=` match, not a udev rule.
#
# The microvm.nix host module itself is imported via `self.inputs.microvm`;
# its `microvm.host.enable` (which defaults to true) is repointed at
# `coder.microvm.enable` below, so the imperative `microvm@<name>.service`
# template is only active when this module is enabled.
{ config, lib, pkgs, self, ... }:
let
  cfg = config.coder.microvm;
  bridgeAddrParts = lib.splitString "/" cfg.bridgeAddress;
  bridgeIp = lib.head bridgeAddrParts;
  bridgePrefix = lib.toInt (lib.last bridgeAddrParts);
  # Network CIDR of the bridge subnet, derived from `bridgeAddress` (e.g.
  # "192.168.100.0/24"), used for NAT `internalIPs`. Derived rather than a
  # separate option so it can never drift from `bridgeAddress`; only the host
  # octets are zeroed, which is correct for the /24 we (and the workspace
  # template) use. Used as a belt-and-suspenders match alongside
  # `internalInterfaces` below.
  bridgeOctets = lib.splitString "." bridgeIp;
  bridgeNetwork =
    "${lib.elemAt bridgeOctets 0}.${lib.elemAt bridgeOctets 1}.${lib.elemAt bridgeOctets 2}.0/${toString bridgePrefix}";
in
{
  imports = [ self.inputs.microvm.nixosModules.host ./provisioner-key.nix ];

  options.coder.microvm = {
    enable = lib.mkEnableOption "Coder microvm.nix host";

    bridgeName = lib.mkOption {
      type = lib.types.str;
      default = "microbr0";
      description = "Name of the Linux bridge used by workspace VMs.";
    };

    bridgeAddress = lib.mkOption {
      type = lib.types.str;
      default = "192.168.100.1/24";
      description = "IP/prefix for the bridge interface (host-side gateway for the VMs).";
    };

    externalInterface = lib.mkOption {
      type = lib.types.str;
      example = "eno1";
      description = "Host uplink that provides internet access (for NAT).";
    };

    authorizedSshKeys = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = ''
        Additional SSH public keys authorised to log in as root on this host.
        The Coder provisioner key is added automatically from the shared
        `coder-provisioner-key` var (see provisioner-key.nix) — no need to
        paste it here. Use this for any extra keys.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # Gate the microvm.nix host services on `coder.microvm.enable` (its own
    # `microvm.host.enable` defaults to true, so we repoint it here). This
    # provides the imperative `microvm@<name>.service` template the Coder
    # provisioner starts/stops.
    microvm.host.enable = cfg.enable;

    # --- Bridge + TAP ports via systemd-networkd ---------------------------
    # The microvm.nix host module imported below already enables networkd for
    # the whole host, so this only ADDS the `10-…` (bridge) and `20-…` (taps)
    # networks to that setup; the uplink (`40-eno1`/`40-eno2`) is unaffected.
    # `systemd.network.enable` is repeated here defensively.
    systemd.network.enable = true;

    # A standalone bridge netdev (no ports at config time); workspace TAPs are
    # attached dynamically by the `20-…-taps` network below.
    systemd.network.netdevs."10-microvm-br" = {
      netdevConfig = {
        Name = cfg.bridgeName;
        Kind = "bridge";
      };
    };
    systemd.network.networks."10-microvm-br" = {
      matchConfig.Name = cfg.bridgeName;
      address = [ cfg.bridgeAddress ];
      # A bridge with no ports has no carrier; keep the gateway (and thus the
      # 192.168.100.1 the VMs use as their default route) up regardless.
      networkConfig.ConfigureWithoutCarrier = true;
    };

    # --- NAT workspace traffic out through the uplink ---------------------
    # Works with the firewall disabled (modules/homelab.nix) — NixOS stands up
    # a standalone nat.service in that case, and on current NixOS programs
    # nftables directly (so it's fine with `networking.firewall.enable = false`).
    #
    # We specify BOTH `internalInterfaces` (the bridge) AND `internalIPs` (the
    # VM subnet). With the `20-…-taps` network below, the `cdr*` TAPs are proper
    # bridge ports, so VM→internet frames ingress the NAT chain reliably as
    # `microbr0`. The extra `internalIPs` source-subnet rule
    # (`-s 192.168.100.0/24 -o <uplink> -j MASQUERADE`) is defensive
    # belt-and-braces: it ignores ingress naming entirely and NATs on source
    # IP, so outbound TCP from a VM can never silently lose NAT even during the
    # brief window before a port is fully enslaved — the exact symptom being
    # raw TCP to 1.1.1.1:53 / 1.1.1.1:443 / GitHub:22 timing out while the frame
    # still leaves the VM with its unroutable 192.168.100.x source. Both rules
    # together are idempotent.
    networking.nat = {
      enable = true;
      internalInterfaces = [ cfg.bridgeName ];
      internalIPs = [ bridgeNetwork ];
      externalInterface = cfg.externalInterface;
    };
    # `networking.nat.enable` already mkDefaults this; kept explicit as
    # belt-and-braces.
    boot.kernel.sysctl."net.ipv4.conf.all.forwarding" = true;

    # --- Enslave workspace TAPs to the bridge -----------------------------
    # microvm.nix's tap-up creates a `cdr*` TAP per `type = "tap"` interface;
    # networkd attaches each to the bridge as soon as the net device appears,
    # via a `Bridge=` match (the systemd-networkd equivalent of the old udev
    # rule / the experiment's `11-cdr-tap` network).
    systemd.network.networks."20-microvm-taps" = {
      matchConfig.Name = "cdr*";
      networkConfig.Bridge = cfg.bridgeName;
    };

    # --- Directories & helpers for the VMs --------------------------------
    systemd.tmpfiles.rules = [
      "d /var/lib/microvms            0755 root root -"
      "d /var/lib/coder-workspaces    0755 root root -"
    ];
    # virtiofsd backs the virtiofs shares the VMs mount (ro-store + workspace).
    environment.systemPackages = [ pkgs.virtiofsd ];

    # --- Let the Coder provisioner in as root -----------------------------
    # The provisioner's public key is pulled automatically from the shared
    # `coder-provisioner-key` var (provisioner-key.nix). Guarded by `.exists`
    # so offsite-backup evaluates cleanly before elserver has generated the key
    # (Nix laziness means `.value` is never forced when `.exists` is false).
    # Any keys in `authorizedSshKeys` are added on top.
    users.users.root.openssh.authorizedKeys.keys =
      cfg.authorizedSshKeys
      ++ (let pubKey = config.clan.core.vars.generators.coder-provisioner-key.files."id_ed25519.pub";
          in lib.optional pubKey.exists pubKey.value);
    services.openssh.settings.PermitRootLogin = "prohibit-password";

    # --- Nix with flakes (the per-workspace flake is built here) ----------
    nix.settings.experimental-features = [ "nix-command" "flakes" ];

    # NOTE: offsite-backup is normally powered off ~23h/day by
    # modules/offsite-backup.nix's `offsite-backup.timer`. Coder workspaces can
    # only run while it is up — disable that timer (or keep the host on) if you
    # want workspaces available around the clock.
  };
}
