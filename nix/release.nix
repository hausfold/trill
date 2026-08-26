# The published Trill.app release this flake installs.
#
# CI-OWNED: .github/workflows/release.yml rewrites these on main after every
# tag, pointing the flake at the ZIP it just published (there is no cask yet;
# when one lands it takes the same version + SHA). Feel-testing a source branch
# goes through the `prebuilt` dev-app injection (`bench try`) instead, which
# ignores these entirely.
#
# Hand-edit only to bootstrap a brand-new release line. `version` carries no
# leading "v"; `sha256` is the release .zip's SHA-256 in hex.
{
  version = "2026.08.26";
  sha256 = "a6f18f732e7c200e3fae0172e6e57fa6d30c5691cef85f7067db8ad88afa3157";
}
