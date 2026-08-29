# Visual assets

Trill's mark is the family's paired cat-ears sitting over its own detail: a
speech bubble with three dots — the banner trill draws. Flat geometry in the
[nebelung](https://github.com/hausfold/nebelung) palette, sky against graphite,
so it reads at 16 px and sits next to perch's green cards and pounce's peach
input bar.

| file | what it is |
|---|---|
| `trill-icon-master.png` | 2048×2048 source for the macOS app-icon slots — sky mark on a dark graphite tile. |

`Trill/Assets.xcassets/AppIcon.appiconset/*.png` are mechanically scaled from
the master; `actool` compiles them into `Assets.car` and writes
`CFBundleIconName`, so the app icon is a build product, not a checked-in
bundle resource. Regenerate every slot with:

```sh
for pair in 16x16:16 16x16@2x:32 32x32:32 32x32@2x:64 128x128:128 \
            128x128@2x:256 256x256:256 256x256@2x:512 512x512:512 512x512@2x:1024; do
  sips -s format png -Z "${pair#*:}" assets/trill-icon-master.png \
    --out "Trill/Assets.xcassets/AppIcon.appiconset/icon_${pair%%:*}.png"
done
```

Keep the master rather than upscaling a slot — 2048 is the only size the mark
exists at above 512, and `512x512@2x` already wants 1024.

Trill is `LSUIElement`, so this icon never reaches the Dock. Where it *is*
seen: System Settings' Notifications / Login Items / Privacy rows, Finder, and
any launcher that resolves the bundle — pounce's palette among them.
