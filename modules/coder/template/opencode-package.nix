# OpenCode 2.x — the AI coding agent CLI (https://opencode.ai), packaged from
# the prebuilt binary that npm publishes rather than built from source.
#
# Why vendor a package at all: nixpkgs DOES ship `opencode`, but only the 1.x
# line (1.15.10 in the workspace VM's pinned nixpkgs, 1.19.0 in
# nixpkgs-unstable at the time of writing). OpenCode 2.x is a rewrite — it
# builds `packages/cli` instead of `packages/opencode`, installs both
# `opencode` and an `opencode2` alias, and drops v1's `completion` subcommand —
# so the nixpkgs derivation cannot just be version-bumped.
#
# Upstream's own flake builds 2.x from source with Bun. This deliberately does
# not: that would pull a second nixpkgs (the flake pins `nixpkgs-unstable`) and
# a multi-hundred-MB Bun `node_modules` fixed-output derivation into every
# workspace build on the microvm host, for a binary we can fetch ready-made.
#
# What npm publishes as `@opencode/cli` is only a launcher: its postinstall
# picks one of the platform packages in `optionalDependencies` and hardlinks
# their `bin/opencode` into place. That payload is a single self-contained Bun
# executable (~210 MiB) — so fetch the platform package directly. No launcher,
# no postinstall, no node_modules.
#
# How to bump:
#   1. Newest 2.x on npm:
#        curl -s https://registry.npmjs.org/@opencode/cli | jq -r '."dist-tags".latest'
#      (the platform package always carries the same version).
#   2. Set `version` below.
#   3. Refresh the hash:
#        nix store prefetch-file --json --hash-type sha256 \
#          "https://registry.npmjs.org/@opencode/cli-linux-x64/-/cli-linux-x64-<version>.tgz"
#      and paste the reported `hash` verbatim.
{
  lib,
  stdenvNoCC,
  fetchurl,
  makeWrapper,
  autoPatchelfHook,
  glibc,
  ripgrep,
  wayland,
}:

stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "opencode";
  version = "2.0.29";

  # x86_64-linux, non-baseline: the binary npm's launcher picks when the CPU
  # reports AVX2 (see its postinstall.mjs). Every microvm host in this homelab
  # is far past Haswell. The `-baseline` package would trade a little speed for
  # pre-AVX2 CPUs; the musl variants are irrelevant on NixOS.
  src = fetchurl {
    url = "https://registry.npmjs.org/@opencode/cli-linux-x64/-/cli-linux-x64-${finalAttrs.version}.tgz";
    hash = "sha256-FLWmY4oaCTrJ1IRZnIRLEMKbRF0EhEtoLMxmjOJlMKI=";
  };

  # The npm tarball unpacks into a single `package/` directory.
  sourceRoot = "package";

  nativeBuildInputs = [
    makeWrapper
    autoPatchelfHook
  ];
  # glibc resolves the interpreter autoPatchelfHook rewrites (the shipped
  # binary asks for /lib64/ld-linux-x86-64.so.2, which NixOS does not have).
  # wayland is NOT a NEEDED library — OpenTUI dlopens it for clipboard images,
  # which is why it goes on LD_LIBRARY_PATH in the wrapper rather than into the
  # ELF's RPATH.
  buildInputs = [
    glibc
    wayland
  ];

  # Bun self-contained executables append the bundled JS and a trailer to the
  # END of the ELF and locate it relative to the file. `strip` destroys that
  # payload: the same derivation under a plain `stdenv` builds fine but the
  # result is the bare Bun runtime — `opencode --version` prints Bun's version.
  # stdenvNoCC already omits the strip hook; dontStrip keeps it that way if the
  # derivation is ever moved onto a normal stdenv.
  dontStrip = true;
  dontConfigure = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall

    install -Dm755 bin/opencode $out/bin/opencode
    # 2.x installs under both names (`opencode2` is how it sits next to a 1.x
    # `opencode`); keep the alias to match upstream's launcher.
    ln -s opencode $out/bin/opencode2

    # ripgrep is what the agent shells out to for search; wayland is for the
    # OpenTUI clipboard path described above. The VM already has both in
    # systemPackages, but wrapping keeps this derivation self-contained.
    wrapProgram $out/bin/opencode \
      --prefix PATH : ${lib.makeBinPath [ ripgrep ]} \
      --prefix LD_LIBRARY_PATH : ${lib.makeLibraryPath [ wayland ]}

    runHook postInstall
  '';

  meta = {
    description = "The open source AI coding agent (OpenCode 2.x)";
    homepage = "https://opencode.ai";
    license = lib.licenses.mit;
    mainProgram = "opencode";
    platforms = [ "x86_64-linux" ];
  };
})
