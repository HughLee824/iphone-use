# iphone-use brand assets

The approved identity combines a rounded phone silhouette with a continuous
swipe cutout. These production exports use the final, right-adjusted gesture
without the touch dot. The source geometry and outlined wordmark are preserved
in [the design kit](iphone-use-final/README.md).

| Asset | Size | Use |
| --- | --- | --- |
| [iphone-use-mark.svg](iphone-use-mark.svg) | 160 × 160 viewBox | Transparent vector symbol |
| [iphone-use-mark-dark.svg](iphone-use-mark-dark.svg) | 160 × 160 viewBox | Light symbol for dark backgrounds |
| `iphone-use-mark.png`, `iphone-use-mark-256.png` | 1024 / 256 px | Transparent symbol exports |
| [iphone-use-wordmark.svg](iphone-use-wordmark.svg) | 350 × 112 viewBox | Light-mode README wordmark |
| [iphone-use-wordmark-dark.svg](iphone-use-wordmark-dark.svg) | 350 × 112 viewBox | Dark-mode README wordmark |
| `iphone-use-wordmark.png`, `iphone-use-wordmark-dark.png` | 1400 × 448 px | Transparent wordmark exports |
| [iphone-use-app-icon.png](iphone-use-app-icon.png) | 1024 × 1024 | Opaque white app icon / avatar |
| `favicon-{16,32,48,64}.png` | Named pixel dimensions | Opaque white browser icons |
| [favicon.ico](favicon.ico) | 16, 32, 48, 64, 256 px | Multi-resolution browser icon |

The master colors are `#171717` and `#F5F5F2`. SVG cutouts are genuinely
transparent; wordmark lettering is outlined Geist Medium 500, with no font
installation dependency. The [Geist license](licenses/geist-OFL.txt) is included.

## Integration

Both READMEs select the appropriate wordmark through a light/dark `<picture>`.
The app icon is copied byte for byte to
`Runner/Assets.xcassets/AppIcon.appiconset/AppIcon.png`. Xcode generates device
sizes; the existing scheme post-action installs the compiled catalog into the
Runner host. Build/install a new Runner to update an existing device icon.

The Codex plugin uses the light/dark mark SVGs for its listing and composer icons.
Its skill uses the opaque app icon for legibility on either theme. Copies in
`skills/iphone-use/assets/` must match these approved exports byte for byte; run
`python3 scripts/sync-plugin.py` to update the self-contained plugin copies.
The plugin archive test verifies that all icon paths survive relocation and
their contents match the brand originals. Plugin 0.1.7 introduces these metadata
fields; existing installations need the updated plugin to display them.

Favicon exports retain exactly the same vector path, using `viewBox="8 8 144 144"`
to reduce empty margins. This leaves 10 design units of top/bottom clear space
and keeps the gesture continuous at 16 px. Do not use the design kit's unadjusted
`mark-16.png`, which is retained as a failed small-size sample. The normal master
has a recommended minimum canvas of 24 px.

The approved assets are merged into this repository and deployed by the separate
[iphone-use-website repository](https://github.com/HughLee824/iphone-use-website).
Future asset edits still need to be copied and deployed there separately. Published
0.2.0 release archives retain their original packaged icon.
Previous AgentSoma assets remain available in [Git history](https://github.com/HughLee824/iphone-use/tree/8410e7d/assets/brand).
Local design archives and generated preview images are not production inputs.

## Re-export

From the repository root, with Node.js and `sharp` available:

```sh
node scripts/export-brand-assets.cjs
```

If `sharp` is installed outside the module search path, set
`NODE_PATH=/path/to/node_modules`. This is a design-time dependency only.
The exporter uses the approved SVG files, updates all production PNG/ICO assets,
the Runner copy and [the SHA-256 manifest](manifest.json). It does not require a
font download or modify approved geometry. To reconstruct the SVGs from their
parameters, follow the [design kit instructions](iphone-use-final/README.md).
