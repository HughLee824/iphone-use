# Brand tools

These tools maintain the approved assets in `assets/brand/`. They are development dependencies, not CLI or plugin runtime dependencies. The npm package is private. Do not install Sharp into the generated root plugin manifest.

Use Node.js 22+ and Python 3.9+. From the repository root:

```sh
npm ci --prefix scripts/brand --ignore-scripts
python3 -m venv .build/brand-venv
.build/brand-venv/bin/python -m pip install -r scripts/brand/requirements.txt
```

The npm lockfile pins Sharp 0.35.5 and its dependency tree; requirements.txt pins Pillow 11.3.0. Sharp uses the locked prebuilt packages, with install scripts disabled. Both dependency directories are ignored. Keep the pinned versions and lockfile together when upgrading; compare generated assets before accepting changes.

Rebuild and check the design kit:

```sh
.build/brand-venv/bin/python scripts/brand/build.py
npm run render --prefix scripts/brand
.build/brand-venv/bin/python scripts/brand/verify.py
```

The verifier rebuilds SVGs in a temporary directory, checks byte equality with the approved references and evaluates raster geometry. Generated previews and validation.json stay ignored. Automated geometry checks do not constitute visual, recognition or print acceptance.

Export production assets:

```sh
npm run export --prefix scripts/brand
```

This updates the production brand files, their manifest and the Runner icon. It never modifies `assets/preview/` or Apple bezel artwork. Review the diff and run the shared engineering checks. The skill icon sources and embedded preview favicon are separate consumers; update them explicitly only when changing approved artwork.
