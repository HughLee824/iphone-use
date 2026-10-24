# Public access release

The [website](https://iphone-use.com), CLI releases, Git marketplace and npm packages are separate distribution channels. Use release notes and package metadata for published versions; a source checkout or successful package install does not establish physical-device acceptance. The website is static; the plugin packages a skill, not an MCP service.

## Source ownership

| Source | Purpose |
| --- | --- |
| Separate `iphone-use-website` repository | Static site source, reviewed demo media, website CI and Cloudflare deployment. |
| `skills/iphone-use/` | Canonical shared operation rules, client adapters and preflight. |
| `plugins/iphone-use/` | Self-contained dual-client distribution; committed copies checked by CI. |
| `.agents/plugins/marketplace.json` | Codex repository marketplace. |
| `.claude-plugin/marketplace.json` | Claude Code repository marketplace. |
| `docs/first-task.md` / `docs/plugins.md` | English first-task path and Chinese plugin guide. |

## Validate changes

```sh
python3 scripts/check.py
```

The shared check runs documentation links, strict SwiftLint, both Swift test suites, Objective-C runtime doubles, Python checks, the unsigned Runner build, Node templates and public installation/bundle checks on macOS. The CI workflow uploads the plugin ZIP/checksum as `client-plugins` for review. Website build and link checks run independently on Ubuntu in the website repository. The release workflow applies the template and plugin checks to binary releases and attaches the plugin ZIP/checksum to its draft; downloaded plugin artifacts are compared with the exact source before creating the draft. Neither workflow has a physical iPhone or claims task acceptance.

## Publish a plugin change

1. Update the canonical skill, adapter or preflight. Before release, use `python3 scripts/plugin/set-plugin-version.py X.Y.Z` to update the shared distribution version; follow [version policy](../CONTRIBUTING.md#versions-and-release-notes).
2. Run `python3 scripts/plugin/sync-plugin.py` and the checks above. Inspect the diff and relocated ZIP contents, including local reference targets and license.
3. Publish the reviewed commit to this public repository. Retain the source commit used for acceptance.
4. From outside the checkout, add the **public repository** as the marketplace, install in each client, and confirm the cached version. Use [the documented client commands](plugins.md).
5. Run the first task sequentially on the phone in each client. Verify a real image read, current references, a real navigation action, final screen state and cleanup. Exercise one safe rejection/refresh path. Record the actual task results, not only tool exit codes.
6. Update from the previous installed plugin, start a fresh session and confirm the new workflow content is loaded. Keep CLI upgrades distinct from plugin upgrades.

Do not silently change content under a published version. For the initial release, a controlled previous local package can verify cache refresh, but label that result as a local-to-public upgrade rather than claiming an older public release existed. Official-directory submissions are separate from this Git distribution.

## Publish the website

Website source and release instructions live in the separate [iphone-use-website repository](https://github.com/HughLee824/iphone-use-website). Its Cloudflare Worker serves the verified public site at `https://iphone-use.com`. The repository's `wrangler.jsonc` declares the public output, real 404 handling and custom domains. Its `main` branch is connected to Cloudflare Workers Builds using the configuration documented in its README, so website changes validate and deploy independently of CLI and plugin releases.

After deployment, verify the exact HTTPS URL without an authenticated session. Check installation anchors, client selection, clipboard success/failure, keyboard navigation, and narrow layouts (320, 375, 414 and 768 CSS pixels) as well as desktop. Keep the deployed website commit in the acceptance record. The website's GitHub Actions artifact is a review/build artifact. Production pushes run the tests, documentation-link checks and static build before Workers Builds deploys the result. Manual Wrangler deployment remains available through the website README.

After deployment, follow the website's two client paths using the public install source. Keep the website's installation text, the English first-task guide, Chinese plugin guide and both READMEs aligned.

## Evidence and rollback

Record date, public site URL, repository commit, plugin version, CLI/client versions, Mac/Xcode/iPhone/iOS versions, signing type, installation source, image-reading/tool evidence, task result, rejection/recovery, upgrade pickup, cleanup, and remaining limitations. Store raw client logs and device captures in ignored `.local/public-access/`. Publish only a deliberately sanitized acceptance summary and reviewed media under `assets/` in the website repository.

If a public source or client task cannot be tested, state exactly what is blocked and leave that part unverified. A working Homebrew installation does not establish a fresh-Mac signing path. A successful local plugin install does not establish a public Git install. A build or deployment receipt does not establish two-client task success.

To roll back website content, revert the website commit and let Cloudflare deploy it, or restore an earlier validated Worker deployment. For a plugin regression, publish a **new patch version** with the corrected or reverted content so client caches refresh. Keep active device sessions disconnected while changing CLI/Runner installations. Reverting a source file without a version bump is not a reliable plugin rollback.
