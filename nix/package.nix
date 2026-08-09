{
  lib,
  stdenvNoCC,
  fetchurl,
  version,
  sha256,
  # The `prebuilt` flake input's store path: normally the empty ./nix/dev-app
  # placeholder, but `bench try` overrides it to a dir holding a locally-built
  # Trill.app when feel-testing a source branch (see flake.nix / nix/dev-app).
  prebuilt,
}:

# Package Trill.app so the rice (and anyone) can install it through Nix instead
# of Homebrew — trill's handle in the flake-lock chain.
#
# Normally we fetch the CI-built release ZIP rather than compiling: trill is an
# Xcode project, and macOS 26 refuses to let a session-less `_nixbld` user apply
# SwiftPM's manifest sandbox, so a from-source Nix build dies at package
# resolution (pounce dodges this only by being plain `swiftc` with zero
# packages). The ZIP is already Developer-ID signed + Apple notarized, which is
# exactly what a stable permissions grant wants — so unpack it verbatim and let
# the rice place it at a fixed path (no re-sign dance).
#
# The one exception is `bench try` feel-testing a source branch: it builds the
# app in your login session (where xcodebuild works) and overrides `prebuilt` to
# that build, so we wrap that .app instead of the release. Same packaging.

let
  # bench points `prebuilt` at a dir containing a freshly-built Trill.app; the
  # placeholder has none, so we fall back to the release ZIP.
  useDev = builtins.pathExists "${prebuilt}/Trill.app";
in

stdenvNoCC.mkDerivation {
  pname = "trill";
  # Tag the dev build so its store path (and the rice's install marker) differ
  # from the release — activation then re-copies when you flip between them.
  version = if useDev then "${version}-dev" else version;

  src =
    if useDev then
      prebuilt
    else
      fetchurl {
        url = "https://github.com/hausfold/trill/releases/download/v${version}/trill-v${version}-macos.zip";
        inherit sha256;
      };

  # `ditto` is the macOS-correct copy/unarchive: the release ZIP is written by
  # `ditto -c -k` and carries the code signature + stapled notarization ticket as
  # bundle contents + xattrs; a locally-built .app carries its own signature.
  # Plain `unzip`/`cp` can drop those; ditto preserves them so the app verifies.
  # The release archive holds Trill.app at top level (built with --keepParent).
  unpackPhase = ''
    runHook preUnpack
    if [ -d "$src/Trill.app" ]; then
      /usr/bin/ditto "$src/Trill.app" ./Trill.app   # dev build injected by bench
    else
      /usr/bin/ditto -x -k "$src" .                 # release ZIP
    fi
    runHook postUnpack
  '';

  dontConfigure = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall
    mkdir -p $out/Applications
    /usr/bin/ditto Trill.app $out/Applications/Trill.app
    runHook postInstall
  '';

  # Don't let Nix strip or re-sign the signed bundle — any rewrite invalidates
  # the signature the permissions grant depends on.
  dontFixup = true;

  meta = {
    description = "Quiet scriptable notification compositor for macOS";
    homepage = "https://github.com/hausfold/trill";
    platforms = lib.platforms.darwin;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
}
