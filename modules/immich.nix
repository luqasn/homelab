{
  config,
  pkgs,
  lib,
  ...
}:
let
  immichDomain = "immich.${config.common.domain}";
  utils = import ../lib {
    inherit config;
    inherit lib;
  };
in
{
  services.immich = {
    enable = true;
    port = 2283;
    accelerationDevices = null;

    settings = {
      server.externalDomain = "https://${immichDomain}";

      notifications.smtp = {
        enabled = true;
        from = config.programs.msmtp.accounts.default.from;
        replyTo = "";
        transport = {
          ignoreCert = false;
          host = config.programs.msmtp.accounts.default.host;
          port = config.programs.msmtp.defaults.port;
          secure = true;
          username = config.programs.msmtp.accounts.default.user;
          password._secret = config.sops.secrets.sendgrid-password.path;
        };
      };
    };
  };


     nixpkgs.overlays = [
       (final: prev: {
immich-kiosk = let
    version = "0.33.0";
    src = prev.fetchFromGitHub {
      owner = "damongolding";
      repo = "immich-kiosk";
      tag = "v${version}";
      hash = "sha256-VIJYgEEiW+JTKkWSY+kaftD08xljZLssYX5/R+thMEc=";
    };

    bunDeps = prev.stdenvNoCC.mkDerivation {
      pname = "immich-kiosk-bun-deps";
      inherit version src;
      sourceRoot = "${src.name}/frontend";
      impureEnvVars = prev.lib.fetchers.proxyImpureEnvVars;
      nativeBuildInputs = [ prev.bun ];

      buildInputs = [ prev.nodejs-slim_latest ];
      dontConfigure = true;
      buildPhase = ''
        bun install --no-progress --frozen-lockfile
      '';
      installPhase = ''
      mkdir -p $out/node_modules
      cp -R ./node_modules $out
      '';
      outputHash = "sha256-1enY+kSfkKvF0vAzWgOED2VXUVAc38KfhVKCYuPten8=";
      outputHashAlgo = "sha256";
      outputHashMode = "recursive";
    };
  in (prev.immich-kiosk.override {
    buildGoModule = prev.buildGoModule.override {
      go = prev.go_1_26;
    };
  }).overrideAttrs (oldAttrs: {
    inherit version src;
    vendorHash = "sha256-OHmsTkMX5+XZrnNlkZJNtCwxQ2eBFFKJpAKOs+JytZA=";

    pnpmDeps = null;
    pnpmRoot = null;

    nativeBuildInputs = builtins.filter (drv:
      drv != prev.pnpmConfigHook && drv != prev.pnpm_9
    ) (oldAttrs.nativeBuildInputs or []) ++ [
      prev.makeBinaryWrapper
    ];
    buildInputs = [ prev.bun prev.typescript ];

    preBuild = ''
      go run github.com/a-h/templ/cmd/templ generate
        export PATH=${lib.makeBinPath [ prev.bun ]}:$PATH
        pushd frontend
        cp -R ${bunDeps}/node_modules node_modules
        patchShebangs ./node_modules
        bun run build
        popd
    '';

    ldflags = [
      "-s"
      "-w"
      "-X main.version=${version}"
    ];
  });

       })
     ];

  users.users.immich.extraGroups = [
    "video"
    "render"
  ];

  services.nginx.virtualHosts.${immichDomain} = {
    forceSSL = true;
    useACMEHost = config.common.domain;
    locations."/" = {
      proxyPass = "http://[::1]:${toString config.services.immich.port}";
      proxyWebsockets = true;
      recommendedProxySettings = true;
      extraConfig = ''
        client_max_body_size 50000M;
        proxy_read_timeout   600s;
        proxy_send_timeout   600s;
        send_timeout         600s;
      '';
    };
  };

  services.immich-kiosk = {
    enable = true;
    settings = {
      immich_url = "http://localhost:${toString config.services.immich.port}";
      immich_api_key._secret = config.sops.secrets.immich-api-key.path;
      immich_users_api_keys.marlena._secret = config.sops.secrets.immich-api-key-marlena.path;

      kiosk = {
        port = 2284;
        behind_proxy = true;
      };
      duration = 45;
      show_time = false;
      show_date = false;
      #      time_format = 24;
      #      date_format = "DD.MM.YYYY";
      #      clock_source = "client";
      #          people = [
      #          ];
      albums = [
        "favorites"
        "favorites@marlena"
#        "2a7cacb8-fbea-47e1-adcc-7899ea2888e6"
      ];
      #      memories = true;
      layout = "splitview";
      show_owner = true;
      show_image_date = true;
      image_date_format = "DD.MM.YYYY";
      show_image_location = true;
    };
  };

  services.nginx.virtualHosts."immich-kiosk.${config.common.internalDomain}" = utils.mkVirtualHost {
    port = config.services.immich-kiosk.settings.kiosk.port;
    internal = true;
  };
}
