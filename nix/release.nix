# The published Trill.app release this flake installs.
#
# CI-OWNED: .github/workflows/release.yml rewrites these on main after every
# tag, pointing the flake at the ZIP it just published — it has done so since
# the release line opened on 2026-08-25, and haus-release[bot] is the only
# author these two values have had since. Never hand-bump them; a hand-typed
# sha ships a flake that refuses to build. (There is no cask yet; when one
# lands it takes the same version + SHA.) Feel-testing a source branch goes
# through the `prebuilt` dev-app injection (`bench try`) instead, which ignores
# these entirely.
#
# Hand-edit only to bootstrap a brand-new release line. `version` carries no
# leading "v"; `sha256` is the release .zip's SHA-256 in hex.
{
  version = "2026.09.12";
  sha256 = "560134ab48e209d451bf44d44eebbbbd2d8e869309460a620969fb8236b7b82d";
}
