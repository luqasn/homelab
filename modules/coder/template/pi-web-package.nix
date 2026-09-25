{
  lib,
  buildNpmPackage,
  fetchNpmDeps,
  fetchurl,
  makeWrapper,
  nodejs,
  nodejs-slim,
  python3,
  pkg-config,
}:

buildNpmPackage (finalAttrs: {
  pname = "pi-web";
  version = "1.202609.0";

  src = fetchurl {
    url = "https://registry.npmjs.org/@jmfederico/pi-web/-/pi-web-${finalAttrs.version}.tgz";
    hash = "sha256-wnTCtycbiVn8FIyP4jMhWUj6x1EEdQrjUtlHnahql7A=";
  };

  postPatch = ''
    cp ${./package-lock.json} package-lock.json
    ${nodejs}/bin/node - <<'NODE'
    const fs = require("fs");
    const pkg = JSON.parse(fs.readFileSync("package.json", "utf8"));
    pkg.dependencies = { ...pkg.dependencies, ...pkg.peerDependencies };
    delete pkg.devDependencies;
    delete pkg.peerDependencies;
    delete pkg.peerDependenciesMeta;
    fs.writeFileSync("package.json", JSON.stringify(pkg, null, 2) + String.fromCharCode(10));
    NODE
  '';

  # Fetcher v2 is required: v1 caches only what the lockfile names, and the
  # vendored lockfile is incomplete — `@earendil-works/pi-tui`, a peer dep of
  # pi-coding-agent, has no entry, so `npm ci` reaches for it at install time
  # and dies with `ENOTCACHED ... pi-tui-0.85.1.tgz` under only-if-cached.
  # (Re-verified against this lockfile: v1 still fails exactly that way.)
  npmDepsFetcherVersion = 2;

  # npmDeps is spelled out rather than left to `npmDepsHash` so the fetcher can
  # be pinned to a single thread.
  #
  # `prefetch-npm-deps` fans the packument fetches out over rayon (one request
  # per package name — ~440 of them here, all to registry.npmjs.org at once)
  # and, unlike the tarball fetches, it SWALLOWS failures:
  #
  #     Err(e) => {
  #         // Log but don't fail - some packages might not need packuments
  #         info!("Warning: couldn't fetch packument for {package_name}: {e}");
  #     }
  #
  # Its retry wrapper only retries network/timeout errors, so a rate-limit or
  # 5xx from the registry is dropped on the floor. The derivation then succeeds
  # with *fewer cache entries than it should have* and therefore a different —
  # but perfectly valid-looking — output hash, which surfaces on the microvm
  # host as the notorious "hash mismatch in fixed-output derivation
  # ...-pi-web-npm-deps.drv". The hash below is correct; it is the fetch that is
  # non-deterministic.
  #
  # RAYON_NUM_THREADS = 1 serialises those requests. It produces byte-identical
  # output (verified: same hash as the parallel fetch) while making a
  # rate-limit-induced silent miss far less likely. It costs ~a minute on the
  # first build and nothing afterwards. With it in place the fetch reproduces:
  # two forced re-fetches via `nix-store --realise --check` both returned the
  # hash below.
  #
  # So if a build DOES report a mismatch, treat it as a signal, not as noise to
  # paper over. Re-pin only when the lockfile actually changed; otherwise retry,
  # because the alternative — pinning whatever the registry just returned —
  # accepts arbitrary content under the name of a fixed-output hash.
  npmDeps = (fetchNpmDeps {
    inherit (finalAttrs) src postPatch;
    name = "${finalAttrs.pname}-${finalAttrs.version}-npm-deps";
    hash = "sha256-Z0nIXS1ActFuagZ8XsLqVQyeEOQxr2dKJLixrDwWSI4=";
    fetcherVersion = 2;
  }).overrideAttrs
    (_: {
      RAYON_NUM_THREADS = "1";
    });

  nativeBuildInputs = [
    makeWrapper
    pkg-config
    python3
  ];

  buildInputs = [ nodejs ];

  dontNpmBuild = true;

  installPhase = ''
    runHook preInstall

    mkdir -p $out/lib/node_modules/pi-web
    cp -r dist node_modules package.json LICENSE README.md $out/lib/node_modules/pi-web/

    mkdir -p $out/bin
    makeWrapper ${nodejs-slim}/bin/node $out/bin/pi-web \
      --add-flags "$out/lib/node_modules/pi-web/dist/cli.js"
    makeWrapper ${nodejs-slim}/bin/node $out/bin/pi-web-server \
      --add-flags "$out/lib/node_modules/pi-web/dist/server/index.js"
    makeWrapper ${nodejs-slim}/bin/node $out/bin/pi-web-sessiond \
      --add-flags "$out/lib/node_modules/pi-web/dist/server/sessiond.js"

    runHook postInstall
  '';

  meta = with lib; {
    description = "Web UI and persistent session manager for Pi Coding Agent";
    homepage = "https://pi-web.dev/";
    license = licenses.mit;
    mainProgram = "pi-web";
    platforms = platforms.all;
  };
})
