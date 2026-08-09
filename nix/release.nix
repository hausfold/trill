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
  version = "0.0.0";
  sha256 = "0000000000000000000000000000000000000000000000000000000000000000";
}
