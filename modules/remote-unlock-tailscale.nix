{
  config,
  pkgs,
  inputs,
  lib,
  ...
}:
let
  # hoopsnake's NixOS module still branches on boot.initrd.systemd.enable to
  # support a scripted stage-1. nixpkgs removed that option (and made reading it
  # throw) when it dropped scripted stage-1 in
  # https://github.com/NixOS/nixpkgs/commit/316b009d0df3, so importing the
  # module unchanged fails to evaluate on current nixos-unstable.
  #
  # Patch the option read out of the module source at evaluation time instead of
  # vendoring the module: the read is always true now (systemd is the only
  # stage-1), and once hoopsnake drops its scripted path upstream the
  # replacement becomes a no-op and this wrapper can be replaced by a plain
  # `inputs.hoopsnake.nixosModules.default`.
  hoopsnakeModule = import (
    builtins.toFile "hoopsnake-module.nix" (
      lib.replaceStrings [ "config.boot.initrd.systemd.enable" ] [ "true" ] (
        builtins.readFile "${inputs.hoopsnake}/nixos/module.nix"
      )
    )
  ) {
    # The upstream module takes flake-parts' `withSystem` only to default its
    # `package` option to the input's own build.
    withSystem =
      _system: f:
      f {
        config.packages.default = inputs.hoopsnake.packages.${pkgs.stdenv.hostPlatform.system}.default;
      };
  };
in
{
  imports = [
    hoopsnakeModule
  ];

  boot.initrd = {
    network = {
      enable = true;
    };
    systemd.extraBin.ping = "${pkgs.iputils}/bin/ping";
  };

  clan.core.vars.generators.initrd-ssh-hoopsnake = {
    files."id_ed25519".neededFor = "activation";
    files."id_ed25519.pub".secret = false;
    runtimeInputs = [
      pkgs.coreutils
      pkgs.openssh
    ];
    script = ''
      ssh-keygen -t ed25519 -N "" -f "$out/id_ed25519"
    '';
  };

  clan.core.vars.generators.hoopsnake-tailscale-client-secret = {
    share = true;
    # bit of a weird one: because normal secrets don't work during activation
    # which is required for initrd setup, we need to use this "dummy" var
    # that is basically a "pass-through"
    prompts.client-secret.description = "the client secret";
    prompts.client-secret.type = "hidden";
    files.client-secret.secret = true;
    files.client-secret.neededFor = "activation";
    script = ''
      cat "$prompts/client-secret" > "$out/client-secret"
    '';
  };

  boot.initrd.systemd.services.hoopsnake = {
    wants = [ "network-online.target" ];
  };

  boot.initrd.network.hoopsnake = {
    enable = true;
    systemd-credentials = {
      privateHostKey.file = config.clan.core.vars.generators.initrd-ssh-hoopsnake.files.id_ed25519.path;
      privateHostKey.encrypted = false;

      clientId.text = "k3YA241CfD11CNTRL";
      clientId.encrypted = false;
      clientSecret.file =
        config.clan.core.vars.generators.hoopsnake-tailscale-client-secret.files.client-secret.path;
      clientSecret.encrypted = false;
    };
    ssh = {
      authorizedKeysFile = pkgs.writeText "authorized_keys" (
        lib.concatStringsSep "\n" config.users.users.root.openssh.authorizedKeys.keys
      );
    };
    tailscale = {
      name = "${config.networking.hostName}-unlock";
      tags = [ "tag:hoopsnake" ];
    };
  };

  boot.initrd.availableKernelModules = [
    "xhci_pci"
  ];
}
