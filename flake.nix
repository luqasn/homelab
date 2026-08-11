{
  inputs.clan-core.url = "https://git.clan.lol/clan/clan-core/archive/main.tar.gz";
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

  outputs =
    {
      self,
      clan-core,
      nixpkgs,
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
