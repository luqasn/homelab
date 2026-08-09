{
  inputs.clan-core.url = "https://git.clan.lol/clan/clan-core/archive/26.05.tar.gz";
  inputs.nixpkgs.follows = "clan-core/nixpkgs";

  inputs.hoopsnake = {
    url = "github:boinkor-net/hoopsnake";
    inputs.nixpkgs.follows = "clan-core/nixpkgs";
  };

  inputs.nixos-mailserver = {
    url = "gitlab:simple-nixos-mailserver/nixos-mailserver";
    inputs.nixpkgs.follows = "clan-core/nixpkgs";
  };

  # Odysseus AI workspace. Pinned to the PR branch that adds the NixOS
  # service module (https://github.com/pewdiepie-archdaemon/odysseus/pull/2568).
  # The module's `package` default builds odysseus from its own source via the
  # host system's pkgs, so following clan-core/nixpkgs here is safe and avoids
  # pulling a second nixpkgs copy.
  inputs.odysseus = {
    url = "github:ToyVo/odysseus/b2a99f5b199c33c1ac3aab21dcadcbb0f949a360";
    inputs.nixpkgs.follows = "clan-core/nixpkgs";
  };

  # microvm.nix — used by modules/coder/microvm-host.nix (runs on
  # offsite-backup) to host Coder workspace VMs. Follows clan-core/nixpkgs so
  # we don't pull a second nixpkgs copy into the evaluation.
  inputs.microvm = {
    url = "github:microvm-nix/microvm.nix";
    inputs.nixpkgs.follows = "clan-core/nixpkgs";
  };

  # nixos-unstable, as the source of `pkgs.coder` for the Coder server
  # (modules/coder/server.nix) AND the per-workspace VM agent. Deliberately
  # does NOT follow clan-core/nixpkgs: coder must track a newer branch than
  # the homelab's pinned nixpkgs (whose `coder` lags). The server module pulls
  # `coder` from here via `import`, and passes this input's `sourceInfo.rev` to
  # the workspace template as `coder_nixpkgs_rev` — so server and every agent
  # are byte-for-byte on the SAME coder revision (the version-matching
  # invariant; see "Agent/server version matching" in modules/coder/README.md).
  # The revision is pinned by `flake.lock`; bump it with
  # `nix flake lock --update-input nixpkgs-coder` (or `nix flake update
  # nixpkgs-coder` on newer Nix) to advance coder. `coder` is a prebuilt Go
  # binary (`fetchurl` + stdenvNoCC), so pulling it across nixpkgs revisions is
  # ABI-safe; note its build input `terraform` is unfree (bsl11), hence the
  # `config.allowUnfree = true` in server.nix's import.
  inputs.nixpkgs-coder = {
    url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  inputs.nixpkgs-immich-kiosk = {
    url = "github:NixOS/nixpkgs/389ed85304b281ca7f306cf8a1eb4378651ca44e";
  };

  outputs =
    {
      self,
      clan-core,
      nixpkgs,
      nixpkgs-coder,
      nixpkgs-immich-kiosk,
      ...
    }@inputs:
    let
      # Usage see: https://docs.clan.lol
      clan = clan-core.lib.clan {
        inherit self;
        imports = [ ./clan.nix ];
        specialArgs = { inherit inputs; };

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
