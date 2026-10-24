# Brand tools

These tools maintain the approved assets in `assets/brand/`. They are development dependencies, not CLI or plugin runtime dependencies. The npm package is private. Do not install Sharp into the generated root plugin manifest.

Use Node.js 22+ and Python 3.9+. From the repository root:

```sh
npm ci --prefix scripts/brand --ignore-scripts
python3 -m venv .build/brand-venv
.build/brand-venv/bin/python -m pip install -r scripts/brand/requirements.txt
```

The npm lockfile pins Sharp 0.35.5 and its dependency tree; requirements.txt pins Pillow 11.3.0. Sharp uses the locked prebuilt packages, with install scripts disabled. Both dependency directories are ignored. Keep the pinned versions and lockfile together when upgrading; compare generated assets before accepting changes.

Check reproducibility without updating the checkout:

```sh
.build/brand-venv/bin/python scripts/brand/check.py
```

CI runs this command in its macOS native job after installing the pinned dependencies, including on dependency-update PRs. The required `test` gate depends on this job. The check copies tracked brand files, the Runner icon and the four generation tools into a temporary directory, then builds, renders, verifies and exports there. Every tracked asset and manifest must remain byte-identical. Local renders and Apple bezel artwork are not copied. Temporary files are removed on success or failure. This check is separate from `scripts/check.py`, so ordinary engineering checks do not require brand dependencies.

Rebuild and check the design kit:

```sh
.build/brand-venv/bin/python scripts/brand/build.py
npm run render --prefix scripts/brand
.build/brand-venv/bin/python scripts/brand/verify.py
```

The verifier rebuilds SVGs in a temporary directory, checks byte equality with the approved references and evaluates raster geometry. Generated previews and validation.json stay ignored. Each report marks manual visual review as `not performed`; automated geometry checks do not constitute visual, recognition or print acceptance. Record any actual manual review separately with the reviewed revision.

Export production assets:

```sh
npm run export --prefix scripts/brand
```

This updates the production brand files, their manifest and the Runner icon. It never modifies `assets/preview/` or Apple bezel artwork. Review the diff and run the shared engineering checks. The skill icon sources and embedded preview favicon are separate consumers; update them explicitly only when changing approved artwork.
