{
  inputs.clan-core = {
    url = "https://git.clan.lol/clan/clan-core/archive/26.05.tar.gz";
    inputs.nixpkgs.follows = "nixpkgs";
  };

  # Take nixpkgs straight from upstream (nixos-26.05) instead of inheriting the
  # copy bundled by clan-core. Every other input that consumes a nixpkgs
  # follows this one, so only a single nixpkgs lands in `flake.lock`.
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

  # Semi-secret data (PII such as the public domains and the upstream mail
  # host) lives in-tree in homelab-private.nix and is scrubbed by the GitHub
  # mirror workflow. See that file's header for details.

  inputs.hoopsnake = {
    url = "github:boinkor-net/hoopsnake";
    inputs.nixpkgs.follows = "nixpkgs";
    # hoopsnake's transitive devshell/generate-go-sri inputs would otherwise
    # pull their own nixpkgs-unstable nodes into flake.lock. Those extra nodes
    # push the root nixpkgs onto a suffixed key (`nixpkgs_3`), which Renovate's
    # nix manager cannot associate with the `nixpkgs` input
    # (renovatebot/renovate#43815), so it stops proposing nixpkgs updates.
    # Following root keeps a single nixpkgs node named `nixpkgs`.
    inputs.devshell.inputs.nixpkgs.follows = "nixpkgs";
    inputs.generate-go-sri.inputs.nixpkgs.follows = "nixpkgs";
  };

  inputs.nixos-mailserver = {
    url = "gitlab:simple-nixos-mailserver/nixos-mailserver/nixos-26.05";
    inputs.nixpkgs.follows = "nixpkgs";
  };

  # Odysseus AI workspace. Pinned to the PR branch that adds the NixOS
  # service module (https://github.com/pewdiepie-archdaemon/odysseus/pull/2568).
  # The pin is the current head (e79eb75) of the ToyVo fork's `nix-add-modules`
  # branch; an earlier rev was force-pushed away and 404'd, so re-pin to the
  # branch head if this one goes stale.
  # The module's `package` default builds odysseus from its own source via the
  # host system's pkgs, so following our nixpkgs here is safe and avoids
  # pulling a second nixpkgs copy.
  inputs.odysseus = {
    url = "github:ToyVo/odysseus/nix-add-modules";
    inputs.nixpkgs.follows = "nixpkgs";
  };

  # microvm.nix — used by modules/coder/microvm-host.nix (runs on
  # offsite-backup) to host Coder workspace VMs. Follows our nixpkgs so we
  # don't pull a second nixpkgs copy into the evaluation.
  inputs.microvm = {
    url = "github:microvm-nix/microvm.nix";
    inputs.nixpkgs.follows = "nixpkgs";
  };

  # Coder is NOT pinned to a nixpkgs branch: the server and the workspace
  # agents share a small overlay pinned to a specific upstream GitHub release
  # (modules/coder/template/coder-overlay.nix), so advancing coder doesn't
  # require waiting on nixos-unstable. Bump it by editing that overlay.
  inputs.nixpkgs-immich-kiosk = {
    url = "github:NixOS/nixpkgs/389ed85304b281ca7f306cf8a1eb4378651ca44e";
  };

  # Pinned to the exact nixpkgs commit that shipped meilisearch 1.45.2 — the
  # format version of the on-disk Meilisearch database used by Karakeep (see
  # modules/karakeep.nix). The homelab's pinned nixpkgs (nixos-26.05) ships
  # 1.43.1, which refuses to open the newer database
  # ("Database version ... is higher ... Downgrade is not supported").
  #
  # This input exists ONLY to provide `meilisearch`; nothing else should use it.
  # Drop it once nixpkgs ships meilisearch >= 1.45.2. Pinning to the
  # bump commit (instead of a channel) keeps the provided version fixed.
  inputs.nixpkgs-meilisearch = {
    url = "github:NixOS/nixpkgs/33b542d89d760488ab3384304939e0bd902126ef";
  };

  # nixos-vex — a per-system OpenVEX feed consumed by the scheduled
  # vulnerability scan (.forgejo/workflows/vuln-scan.yml). Its NixOS module
  # (imported in modules/shared.nix) adds `system.build.vexFeed`, which drops
  # statements that cannot apply to this configuration (a CVE in xfs code while
  # no xfs filesystem is ever mounted, sshd password auth while it is disabled,
  # ...), so grype suppresses those findings instead of reporting them. The goal
  # is zero *untriaged* findings, not zero findings.
  #
  # Follows our nixpkgs so only a single nixpkgs node lands in flake.lock — a
  # second nixpkgs node pushes the root `nixpkgs` onto a suffixed key that
  # Renovate's nix manager cannot associate (see the hoopsnake note above), and
  # makes it stop proposing nixpkgs updates. nixos-vex's own pins (unstable, and
  # a separate tools nixpkgs for its `packages`) are irrelevant here: the module
  # only inspects the *consuming* system's config and pkgs.
  inputs.nixos-vex = {
    url = "github:datosh/nixos-vex";
    inputs.nixpkgs.follows = "nixpkgs";
    inputs.nixpkgs-tools.follows = "nixpkgs";
    inputs.sbomnix.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    {
      self,
      clan-core,
      nixpkgs,
      nixpkgs-immich-kiosk,
      ...
    }@inputs:
    let
      # Usage see: https://docs.clan.lol
      clan = clan-core.lib.clan {
        inherit self;
        imports = [ ./clan.nix ];
        specialArgs = {
          inherit inputs;
          # In-tree semi-secret PII, scrubbed by the GitHub mirror workflow.
          homelabPrivate = import ./homelab-private.nix;
        };

        # Customize nixpkgs
        # pkgsForSystem =
        #   system:
        #   import nixpkgs {
        #     inherit system;
        #     config = {
        #       allowUnfree = true;
        #     };
        #     overlays = [];
        #   };
      };
    in
    {
      inherit (clan.config) nixosConfigurations nixosModules clanInternals;
      clan = clan.config;
      # Add the Clan cli tool to the dev shell.
      # Use "nix develop" to enter the dev shell.
      devShells =
        nixpkgs.lib.genAttrs
          [
            "x86_64-linux"
            "aarch64-linux"
            "aarch64-darwin"
            "x86_64-darwin"
          ]
          (system: {
            default = clan-core.inputs.nixpkgs.legacyPackages.${system}.mkShell {
              packages = [ clan-core.packages.${system}.clan-cli ];
            };
          });
    };
}
