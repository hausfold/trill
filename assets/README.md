# Visual assets

Trill's mark is the family's paired cat-ears sitting over its own detail: a
notification banner — an avatar dot and two lines of text — which is the thing
trill draws. Flat geometry in four
[nebelung](https://github.com/hausfold/nebelung) tokens: `yellow` (#F7E2B5) for
the ears and the dot, `surface0` (#343434) for the tile, `surface1` (#494949)
for the banner card, `surface2` (#5C5C5C) for the text lines. It reads at 16 px
and sits next to perch's `green` cards and pounce's `peach` input bar.

The inverted tile turns that over — yellow ground, `surface0` ears and card,
the dot still yellow — and swaps the two text lines for `mantle` (#191919) at
0.45, because on the inverted card a gray steps darker rather than lighter,
the way nebelung's second fog layer does.

| file | what it is |
|---|---|
| `trill-icon-master.svg` | **The mark's source of record.** The same geometry in a 100-unit viewBox, colours as nebelung hexes; the brand kit's `docs/design.md` is the standard it answers to. The PNG master renders from it, at any size. |
| `trill-icon-master.png` | 2048×2048 source for the macOS app-icon slots. |
| `trill-square-inverted.svg` | **The inverted tile's source of record**, same geometry, same viewBox: yellow ground, dark shapes. For a light surface, and for the logo sheet where the standard tile would disappear into the page. |
| `trill-square-inverted.png` | 2048×2048, rendered from it. Not an app-icon source: the app icon is the standard tile. |
| `trill-banner.png` | 1200×348 identity banner — the yellow wordmark beside the mark on a rounded graphite tile, on the family's shared banner lockup. What the README opens with. |

Those hexes are **baked into the PNGs**. Nothing here follows
`~/.config/trill/theme.json`, which retints the cards trill *draws* at runtime:
these files are the trill surfaces a theme cannot reach. A palette change in
nebelung means swapping the hexes in `trill-icon-master.svg`, re-rendering the
PNG master from it and then every slot — and redrawing `trill-banner.png` from
the brand kit, which neither the SVG nor the `sips` loop below can do for you:
the loop derives square slots from the 2048² master, and there is no source for
the wordmark lockup in this repo.

`Trill/Assets.xcassets/AppIcon.appiconset/*.png` are mechanically scaled from
the master; `actool` compiles them into `Assets.car` and writes
`CFBundleIconName`, so the app icon is a build product, not a checked-in bundle
resource. Regenerate every slot with:

```sh
# both PNGs, from their vector sources. resvg is what the committed PNGs were
# checked against; a different rasteriser will not land byte-for-byte on them.
# Only the first is an app-icon master; the inverted tile has no slots.
nix run nixpkgs#resvg -- assets/trill-icon-master.svg assets/trill-icon-master.png
nix run nixpkgs#resvg -- assets/trill-square-inverted.svg assets/trill-square-inverted.png

for pair in 16x16:16 16x16@2x:32 32x32:32 32x32@2x:64 128x128:128 \
            128x128@2x:256 256x256:256 256x256@2x:512 512x512:512 512x512@2x:1024; do
  sips -s format png -Z "${pair#*:}" assets/trill-icon-master.png \
    --out "Trill/Assets.xcassets/AppIcon.appiconset/icon_${pair%%:*}.png"
done
```

Keep the PNG master rather than upscaling a slot — `512x512@2x` already wants
1024. If something ever wants vector rather than a raster slot, it takes
`trill-icon-master.svg`; nothing does today.

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
