# dev-app — the source-build injection point

This directory is the default value of the flake's `prebuilt` input, and it is
**deliberately empty** (no `Trill.app`). When it's empty, `nix/package.nix`
fetches the CI-built release ZIP as normal.

`bench try` / `bench try-batch` use it to feel-test a trill **source** branch
without waiting on a release: because macOS 26 blocks a from-source Nix build
(the `_nixbld` user can't apply SwiftPM's manifest sandbox — see
`../package.nix`), bench builds `Trill.app` from the branch **in your login
session** (where `xcodebuild` works), signs it with a stable identity under the
`com.hausfold.trill.dev` bundle id, and points this input at that build:

```
--override-input trill/prebuilt path:/path/to/built-app-dir
```

The package then packages *that* app instead of the release. Nothing here needs
committing per build — the override is transient, per `bench try` invocation.
