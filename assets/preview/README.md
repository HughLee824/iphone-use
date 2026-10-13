# Apple Product Bezels

These are original, unmodified Apple PNGs for the local preview. They are **not covered by the project MIT license**. Retain [Apple-Artwork-License.rtf](Apple-Artwork-License.rtf) with them.

Source: [Apple Design Resources — Product Bezels](https://developer.apple.com/design/resources/#product-bezels). `catalog.json` records each official iPhone 11–16 archive URL and SHA-256, original PNG path and SHA-256, screen aperture geometry, and model identity source. These six archives carry the retained App Store Marketing Artwork License Agreement. These existing assets are retained and packaged at the project owner’s explicit request. The agreement is scoped to App Store-related uses; this tool’s use and redistribution have not been confirmed as authorized by Apple. Retention and integrity checks are not a license clearance.

## Exact model selection

The session reads `hardwareProperties.productType` from its existing CoreDevice discovery. Both standard and runner pass it to the same preview implementation. Only an exact catalog key selects artwork; marketing name, screen resolution, and aspect ratio never select a model. The mapping was checked against Apple Xcode 27 CoreSimulator profiles (`representedModelIdentifiers` and `marketing-name`). Runtime selection does not read simulator profiles.

One neutral-color portrait PNG is included per model. This represents the model, not the connected phone's finish. CSS rotates the artwork for either landscape direction and places the already-oriented frame in its measured aperture. PNGs are independently cached; no bezel is baked into screenshots, JPEG frames, or recordings.

| productType | Appearance |
| --- | --- |
| `iPhone12,1` | iPhone 11 |
| `iPhone12,3` | iPhone 11 Pro |
| `iPhone12,5` | iPhone 11 Pro Max |
| `iPhone13,1` | iPhone 12 mini |
| `iPhone13,2` | iPhone 12 |
| `iPhone13,3` | iPhone 12 Pro |
| `iPhone13,4` | iPhone 12 Pro Max |
| `iPhone14,2` | iPhone 13 Pro |
| `iPhone14,3` | iPhone 13 Pro Max |
| `iPhone14,4` | iPhone 13 mini |
| `iPhone14,5` | iPhone 13 |
| `iPhone14,7` | iPhone 14 |
| `iPhone14,8` | iPhone 14 Plus |
| `iPhone15,2` | iPhone 14 Pro |
| `iPhone15,3` | iPhone 14 Pro Max |
| `iPhone15,4` | iPhone 15 |
| `iPhone15,5` | iPhone 15 Plus |
| `iPhone16,1` | iPhone 15 Pro |
| `iPhone16,2` | iPhone 15 Pro Max |
| `iPhone17,1` | iPhone 16 Pro |
| `iPhone17,2` | iPhone 16 Pro Max |
| `iPhone17,3` | iPhone 16 |
| `iPhone17,4` | iPhone 16 Plus |

## Coverage and fallback

The catalog contains 23 models across iPhone 11–16, including their mini, Plus, Pro and Pro Max variants where applicable. SE and e models have no matching PNG in the collected archives. iPhone 17 / Air and iPhone 18 artwork uses a different Apple Design Resources License with software-embedding restrictions and is deliberately excluded from the package. Covered newer models instead use independently drawn CSS frames. Other devices, including unconfirmed identifiers, use a generic drawn frame. There is no guessed model substitute or runtime download. See the repository document `docs/preview-drawn-frames.md` for parameters and provenance.

Missing identity, unknown model, missing/corrupt catalog or image, failed integrity check, image-load failure, or an incompatible live-frame ratio falls back to a drawn frame. Frame ratio is only a layout safety check after exact model selection. A supported model's notch and rounded corners obscure the corresponding rectangular image edges; the plain-view mode has been removed. Use the original CLI observation screenshot to inspect every pixel.

## Packaging and maintenance

Source builds locate this directory relative to `.build`. Releases copy only `catalog.json`, this README, the retained license, and PNGs explicitly referenced by the catalog into `libexec/iphone-use/preview`. The 23 PNGs total about 16.3 MiB. `build-info.json` records all file digests; release verification rejects missing, altered or unexpected preview files. Copy the complete release directory when relocating an installation; a standalone binary falls back to a drawn frame.

To add a model, first check the applicable archive license, confirm its exact productType from Apple model metadata, copy its original PNG without modification, and record provenance, digest and measured aperture in the catalog. Validate both portrait and landscape geometry and run the preview and release tests. Do not alias a device merely because its screen dimensions match. Automated coverage of all catalog entries is not a claim of physical-device testing on all 23 models.
