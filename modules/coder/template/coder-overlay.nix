# Coder overlay: pin `pkgs.coder` to a specific upstream GitHub release.
#
# nixpkgs' `coder` package is a thin `fetchurl` wrapper around the prebuilt
# release binaries published on github.com/coder/coder. This overlay replaces
# its `version` + `src` with a pinned release, so we can track a Coder version
# newer than whatever the homelab's pinned `nixpkgs` ships, without carrying a
# whole second nixpkgs branch just for coder.
#
# This file is the SINGLE SOURCE OF TRUTH for the Coder version run by BOTH the
# Coder server (modules/coder/server.nix) and every workspace agent. The server
# applies it over the host's `pkgs`; the template writes it next to the
# per-workspace flake (modules/coder/template/main.tf) and imports it there.
# Server and agent MUST run the same version — otherwise the agent rejects the
# server's RPC API version ("server is at version X, behind requested minor
# version Y") and never connects. Bump this file, then redeploy elserver AND
# re-push the workspace template so both sides move together.
#
# How to bump:
#   1. Pick a tag, e.g. https://github.com/coder/coder/releases/tag/v2.37.2
#      (latest stable is reported by github.com/coder/coder/releases/latest).
#   2. Set `version` below (no leading "v").
#   3. Fill in the four `hash` values from the release's
#      `coder_<version>_checksums.txt`, converting hex -> SRI, e.g.
#        nix hash convert --hash-algo sha256 --to sri <sha256-hex>
final: prev:
let
  # Latest stable release (github's releases/latest). The mainline track would
  # be e.g. "2.37.2" — same steps, just newer hashes.
  version = "2.36.6";

  # One entry per platform nixpkgs builds `coder` for: the release asset name
  # (without the `coder_<version>_` prefix + extension) and its SRI hash.
  assets = {
    x86_64-linux = {
      asset = "linux_amd64";
      ext = "tar.gz";
      hash = "sha256-VXm0K7A+aqZGqfGQhi5lo9rfpjUylrqZVT/pW4UDKcI=";
    };
    aarch64-linux = {
      asset = "linux_arm64";
      ext = "tar.gz";
      hash = "sha256-jof9EX3Xb73dFr51eAOliuDPEfUnkdLul3ZdKU4Vv5w=";
    };
    x86_64-darwin = {
      asset = "darwin_amd64";
      ext = "zip";
      hash = "sha256-xxl2i5zIRe+oA6qJo8RiyqOG9kZTc6uoVF6gHfJhYoM=";
    };
    aarch64-darwin = {
      asset = "darwin_arm64";
      ext = "zip";
      hash = "sha256-vaz+mpt4hNhN9Jc39wNOnh0/Q5RjenXyGKl7BgMtj10=";
    };
  };

  system = prev.stdenv.hostPlatform.system;
  asset = assets.${system} or (throw "coder-overlay: unsupported platform '${system}'");
in
{
  coder = prev.coder.overrideAttrs (_: {
    inherit version;
    src = prev.fetchurl {
      url = "https://github.com/coder/coder/releases/download/v${version}/coder_${version}_${asset.asset}.${asset.ext}";
      hash = asset.hash;
    };
  });
}
