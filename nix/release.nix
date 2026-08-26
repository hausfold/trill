# The published Trill.app release this flake installs.
#
# CI-OWNED once a release line exists: trill's release workflow (to be added
# with the first `bench release trill`) will rewrite these on every tag — the
# same version + SHA it stamps into the Homebrew cask. Until then these are
# bootstrap placeholders: there is no release yet, so the flake only works
# through the `prebuilt` dev-app injection (`bench try` on a source branch).
#
# Hand-edit only to bootstrap a brand-new release line. `version` carries no
# leading "v"; `sha256` is the release .zip's SHA-256 in hex.
{
  version = "2026.08.25";
  sha256 = "5f66b8d588adeab54e90c4e0a2c8aa0e692058d193eff10366f9d95bca0aa426";
}
