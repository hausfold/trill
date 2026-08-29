# Visual assets

Trill's mark is the family's paired cat-ears sitting over its own detail: a
notification banner — an avatar dot and two lines of text — which is the thing
trill draws. Flat geometry in four
[nebelung](https://github.com/hausfold/nebelung) tokens: `yellow` (#F7E2B5) for
the ears and the dot, `surface0` (#343434) for the tile, `surface1` (#494949)
for the banner card, `surface2` (#5C5C5C) for the text lines. It reads at 16 px
and sits next to perch's `green` cards and pounce's `peach` input bar.

| file | what it is |
|---|---|
| `trill-icon-master.png` | 2048×2048 source for the macOS app-icon slots. |
| `trill-banner.png` | 1200×348 identity banner — the yellow wordmark beside the mark on a rounded graphite tile, on the family's shared banner lockup. What the README opens with. |

Those hexes are **baked into the PNGs**. Nothing here follows
`~/.config/trill/theme.json`, which retints the cards trill *draws* at runtime:
these files are the trill surfaces a theme cannot reach. A palette change in
nebelung means re-rendering the icon master and every slot by hand — and
redrawing `trill-banner.png` from the brand kit, which the `sips` loop below
cannot do for you: it derives square slots from the 2048² master and there is
no source for the wordmark lockup in this repo.

`Trill/Assets.xcassets/AppIcon.appiconset/*.png` are mechanically scaled from
the master; `actool` compiles them into `Assets.car` and writes
`CFBundleIconName`, so the app icon is a build product, not a checked-in bundle
resource. Regenerate every slot with:

```sh
for pair in 16x16:16 16x16@2x:32 32x32:32 32x32@2x:64 128x128:128 \
            128x128@2x:256 256x256:256 256x256@2x:512 512x512:512 512x512@2x:1024; do
  sips -s format png -Z "${pair#*:}" assets/trill-icon-master.png \
    --out "Trill/Assets.xcassets/AppIcon.appiconset/icon_${pair%%:*}.png"
done
```

Keep the master rather than upscaling a slot — `512x512@2x` already wants 1024,
and there is no vector master. If hausfold.co, a cask, or Icon Composer ever
needs one, it has to be drawn.

## Two things the master deliberately does not do

**No inset, no shadow, no gloss.** The tile is full-bleed flat colour. macOS 26
adds the padding, the drop shadow and the specular pass itself when it draws
any app icon — perch ships exactly this flat and renders with all three — so
baking them in would double them. An Icon Composer `.icon` file is the only way
to control that pass per-layer, and no repo in the family has one.

**No re-tinting.** See above: the icon is static.

Trill is `LSUIElement`, so this icon never reaches the Dock. Where it *is* seen:
System Settings' Notifications / Login Items / Privacy rows, Finder, onboarding's
replica of the Notifications row (`Trill/UI/OnboardingAssistantPanel.swift`, via
`NSApp.applicationIconImage`), and any launcher that resolves the bundle —
pounce's palette among them.
