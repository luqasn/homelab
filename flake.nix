{
  inputs.clan-core = {
    # Clan publishes release branches named after NixOS channels. `main` tracks
    # nixos-unstable, matching our nixpkgs pin above (26.05 would track the
    # stable channel).
    url = "https://git.clan.lol/clan/clan-core/archive/main.tar.gz";
    inputs.nixpkgs.follows = "nixpkgs";
  };

  # Take nixpkgs straight from upstream (nixos-unstable) instead of inheriting
  # the copy bundled by clan-core. Every other input that consumes a nixpkgs
  # follows this one, so only a single nixpkgs lands in `flake.lock`.
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  # nixos-unstable-small carries PHP security fixes earlier than
  # nixos-unstable, but not all packages are built on Hydra there. Keep it as a
  # second input and take only the prebuilt PHP packages from it; everything
  # else stays on the cached nixos-unstable package set.
  inputs.nixpkgs-small.url = "github:NixOS/nixpkgs/nixos-unstable-small";

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
    # nixos-mailserver tracks NixOS unstable on `main` (there is no
    # `nixos-unstable` branch; release branches are named after stable
    # channels, e.g. `nixos-26.05`).
    url = "gitlab:simple-nixos-mailserver/nixos-mailserver/main";
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
      ...
    }@inputs:
    let
      # clan-core's clan-cli passes combined wrapper flags
      # (e.g. "--unset LD_LIBRARY_PATH") as single `makeWrapperArgs` entries.
      # nixpkgs used to turn that array into a space-separated shell string and
      # split it again, but with structured attrs each element is now forwarded
      # verbatim, so the Python wrapper hook dies with "makeWrapper doesn't
      # understand the arg --unset LD_LIBRARY_PATH". Split those flags until
      # clan-core ships the fixed argument list.
      clanCli =
        system:
        let
          package = clan-core.packages.${system}.clan-cli;
        in
        package.overrideAttrs (old: {
          makeWrapperArgs = nixpkgs.lib.concatMap (
            arg:
            if nixpkgs.lib.hasPrefix "--unset " arg then
              [
                "--unset"
                (nixpkgs.lib.removePrefix "--unset " arg)
              ]
            else
              [ arg ]
          ) (old.makeWrapperArgs or [ ]);
        });

      # Toolchain for .forgejo/workflows/vuln-scan.yml. Keeping it in the flake
      # pins sbomnix/grype/jq to this repo's nixpkgs instead of whatever the
      # flake registry happens to point at, and lets the workarounds below live
      # next to the other nixpkgs fixes.
      #
      # nixos-unstable currently ships python3Packages.typepy 2.0.0 while
      # sqliteschema, simplesqlite and pytest-md-report still declare
      # `typepy<2`, so sbomnix (which reaches them through df-diskcache) fails
      # its runtime dependency check. Relax the constraint; the fixes are
      # merged to nixpkgs staging but have not reached nixos-unstable yet:
      # https://github.com/NixOS/nixpkgs/pull/573108
      #
      # `reuse` (another sbomnix dependency) is hit by the structured-attrs
      # migration: list attributes such as `sphinxBuilders` are no longer
      # exported to the build scripts, so only the html docs are built and the
      # `man` output is left missing. Passing a space-separated string restores
      # what the sphinx hook expects (it evals the value into an array). Tracked
      # upstream as https://github.com/NixOS/nixpkgs/issues/576624.
      #
      # sbomnix has the same `makeWrapperArgs` problem as clan-cli above: its
      # single "--prefix PATH : ..." entry reaches makeWrapper as one argument.
      # Split it back up.
      vulnScanTools =
        system:
        let
          pkgs = import nixpkgs {
            inherit system;
            overlays = [
              (_final: prev: {
                python3 = prev.python3.override {
                  packageOverrides = _pyFinal: pyPrev: {
                    sqliteschema = pyPrev.sqliteschema.overridePythonAttrs (old: {
                      pythonRelaxDeps = (old.pythonRelaxDeps or [ ]) ++ [ "typepy" ];
                    });
                    simplesqlite = pyPrev.simplesqlite.overridePythonAttrs (old: {
                      pythonRelaxDeps = (old.pythonRelaxDeps or [ ]) ++ [ "typepy" ];
                    });
                    pytest-md-report = pyPrev.pytest-md-report.overridePythonAttrs (old: {
                      pythonRelaxDeps = (old.pythonRelaxDeps or [ ]) ++ [ "typepy" ];
                    });
                    reuse = pyPrev.reuse.overridePythonAttrs (old: {
                      sphinxBuilders = "html man";
                    });
                  };
                };
              })
              (_final: prev: {
                sbomnix = prev.sbomnix.overrideAttrs (old: {
                  makeWrapperArgs = nixpkgs.lib.concatMap (
                    arg:
                    if nixpkgs.lib.hasPrefix "--prefix PATH : " arg then
                      [
                        "--prefix"
                        "PATH"
                        ":"
                        (nixpkgs.lib.removePrefix "--prefix PATH : " arg)
                      ]
                    else
                      [ arg ]
                  ) (old.makeWrapperArgs or [ ]);
                });
              })
            ];
          };
        in
        pkgs.symlinkJoin {
          name = "vuln-scan-tools";
          paths = [
            pkgs.sbomnix
            pkgs.grype
            pkgs.jq
          ];
        };

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
      # Vulnerability-scan toolchain; see the comment on vulnScanTools above.
      # Only the native x86_64 runner in .forgejo/workflows/vuln-scan.yml uses
      # it.
      packages = nixpkgs.lib.genAttrs [ "x86_64-linux" ] (system: {
        vuln-scan-tools = vulnScanTools system;
      });
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
              packages = [ (clanCli system) ];
            };
          });
    };
}
