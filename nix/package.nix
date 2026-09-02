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

# Package Trill.app so haus (and anyone) can install it through Nix instead
# of Homebrew — trill's handle in the flake-lock chain.
#
# Normally we fetch the CI-built release ZIP rather than compiling: trill is an
# Xcode project, and macOS 26 refuses to let a session-less `_nixbld` user apply
# SwiftPM's manifest sandbox, so a from-source Nix build dies at package
# resolution (pounce dodges this only by being plain `swiftc` with zero
# packages). The ZIP is already Developer-ID signed + Apple notarized, which is
# exactly what a stable permissions grant wants — so unpack it verbatim and let
# haus place it at a fixed path (no re-sign dance).
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
  # Tag the dev build so its store path (and haus's install marker) differ
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

  # `bin/trill` is a symlink, never a copy. The app binary IS the CLI — one
  # executable serves the daemon and every verb — and it is signed and notarized
  # as part of the bundle, so a copy sitting outside the .app would be nested
  # code torn out of the seal it was signed under. (No case-insensitive clash to
  # dodge here, unlike perch's `perch-cli`: `$out/bin/trill` and
  # `Contents/MacOS/Trill` differ in directory, not just in case.)
  #
  # This is what makes `trill` resolve for a PROFILE install — someone who put
  # `pkgs.trill` in their packages and expects the name to work.
  #
  # A desktop that copies the bundle to a fixed /Applications path is a
  # different case, and haus's `haus.notifications.compositor` room settled it
  # the other
  # way from perch's: perch gets a `perch-cli-link` into /Applications because
  # nothing else in haus answers `perch`, while haus already ships a `trill`
  # WRAPPER that resolves the bundle at call time. A second bin/trill there
  # would be a file collision, not a redundancy — and the wrapper is the better
  # answer anyway, because whether Trill.app exists is a runtime fact and a
  # symlink into a missing bundle is a `trill` that `command -v` finds and every
  # call fails on. Nothing about that makes this link wrong; the two answer
  # different installs.
  installPhase = ''
    runHook preInstall
    mkdir -p $out/Applications
    /usr/bin/ditto Trill.app $out/Applications/Trill.app
    # Defensive, the way perch's is: a hand-bootstrapped pin or a dev bundle
    # built without the app target would leave a dangling bin/trill, which is
    # worse than no bin/trill — `command -v trill` would succeed and every
    # call would fail.
    if [ -x "$out/Applications/Trill.app/Contents/MacOS/Trill" ]; then
      mkdir -p $out/bin
      ln -s $out/Applications/Trill.app/Contents/MacOS/Trill $out/bin/trill
    fi
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
