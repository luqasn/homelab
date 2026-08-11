{
  config,
  lib,
  self,
  ...
}:
let
  utils = import ../lib {
    inherit config;
    inherit lib;
  };
in
{
  # Upstream NixOS module from the odysseus flake (PR #2568). Self-contained:
  # its `package` default builds odysseus from its own source via the host
  # system's pkgs (applying its own overlay), so importing this alone is
  # enough -- no nixpkgs.overlays wiring needed.
  imports = [ self.inputs.odysseus.nixosModules.default ];

  services.odysseus = {
    enable = true;

    # Bind loopback; nginx (below) fronts it. Don't open the firewall.
    host = "127.0.0.1";

    # dataDir stays at the default /var/lib/odysseus, which elserver mounts on a
    # ZFS dataset (see machines/elserver/configuration.nix). Both the app and
    # chroma services get ConditionPathIsMountPoint set there so they wait for
    # the dataset before starting.

    # First-run admin credentials, LLM endpoint, and API keys come from an env
    # file. Wire a sops-backed file once populated, e.g.:
    #   environmentFile = config.sops.secrets.odysseus-env.path;
    # See .env.example in the odysseus source for the available variables
    # (ODYSSEUS_ADMIN_USER, ODYSSEUS_ADMIN_PASSWORD, LLM_HOST, API keys, ...).
    # Left null here so the config evaluates without secrets; set it before
    # relying on the service.
    environmentFile = null;

    # Opt-in extras (all off by default -- flip as needed):
    #   searxng.enable         bundled SearXNG metasearch (requires a non-default
    #                          searxng.secretKey; the module asserts on this)
    #   llamaCpp.enable        bundle llama.cpp (llama-server) for GGUF serving
    #   llamaCpp.package       llama.cpp build (default pkgs.llama-cpp; override
    #                          for GPU, e.g. pkgs.llama-cpp-rocm / -vulkan)
    #   extraPythonPackages    extra deps merged into the app env (ps: [ ... ])
    #   extraEnvironmentVariables  app env overrides (escape hatch)
  };

  services.nginx.virtualHosts."odysseus.${config.common.internalDomain}" = utils.mkVirtualHost {
    port = config.services.odysseus.port;
    internal = true;
  };
}
