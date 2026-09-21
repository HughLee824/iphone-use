# HughLee824 Homebrew Tap

> iPhone-use is the new local project identity. Its renamed repository/distribution/plugin channel has not been published by this change; the commands below target that upcoming channel. Existing Logo assets remain unchanged.


Homebrew distribution for [iPhone-use](https://github.com/HughLee824/iphone-use).

Install the stable release:

```sh
brew install HughLee824/tap/iphone-use
iphone-use --version
```

The first distribution targets Apple Silicon on macOS 15 or later. The package contains the precompiled CLI and matching iOS Runner. Device setup separately requires full Xcode and the user's own Apple development signing. See [installation and setup](https://github.com/HughLee824/iphone-use/blob/main/docs/install.md).

To upgrade or uninstall:

```sh
brew update
brew upgrade iphone-use
brew uninstall iphone-use
```

Disconnect active iPhone-use sessions before upgrading. Run `iphone-use setup --device <UDID>` again if requested. Uninstalling the formula leaves your local signing state and the iPhone Runner intact.

## Maintainers

After publishing a stable GitHub Release in `HughLee824/iphone-use`, run **Actions → Update iPhone-use** on `main` with its version, without the leading `v`.

The workflow rejects draft and prerelease versions, checks the archive checksum, CLI/Runner file manifest and source commit against the release tag, and regenerates the formula from that tag's source. Only an exact match with the release's `iphone-use.rb` is committed to this Tap's `main`. The workflow uses this repository's `GITHUB_TOKEN`; no cross-repository write token is needed. Repeating the same version is a no-op. Do not edit the URL and SHA-256 independently.

Formula generation and the workflow template are maintained in [iPhone-use's packaging directory](https://github.com/HughLee824/iphone-use/tree/main/packaging/homebrew-tap). Sync template changes deliberately; normal formula updates only change `Formula/iphone-use.rb`.

MIT licensed; see [LICENSE](https://github.com/HughLee824/iphone-use/blob/main/LICENSE).
