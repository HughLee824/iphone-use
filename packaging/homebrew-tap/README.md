# HughLee824 Homebrew Tap

> iPhone-use 0.2.1 is published and the public Tap provides that version. The package includes the approved Runner Logo; the separate plugin ZIP is version 0.1.6. Repository, Release and plugin versions update independently. Existing 0.2.0 assets remain unchanged.


Homebrew distribution for [iPhone-use](https://github.com/HughLee824/iphone-use).

Install the stable release:

```sh
brew install HughLee824/tap/iphone-use
iphone-use --version
```

The package targets Apple Silicon and contains the precompiled CLI and optional iOS Runner. Both modes require full Xcode. The binary deployment floor is macOS 15, but standard mode currently requires macOS/iOS 27; it connects with `iphone-use connect --device <UDID> --mode standard` without setup or development signing. Only Runner mode requires `iphone-use setup --device <UDID>` and the user's own Apple development signing. See [installation and setup](https://github.com/HughLee824/iphone-use/blob/main/docs/install.md).

To upgrade or uninstall:

```sh
brew update
brew upgrade iphone-use
brew uninstall iphone-use
```

Disconnect active sessions before upgrading. When moving from the old `agentsoma` formula, uninstall it before installing `iphone-use`: both expose the compatibility command and conflict. Local configuration is retained. Renamed Runner deployments require new setup; standard mode does not. Uninstalling the formula leaves local signing state and installed iPhone apps intact.

## Formula-scoped trust

On Homebrew versions enforcing Tap Trust, installation may fail while loading the legacy `agentsoma` formula for the compatibility-command conflict check, even after the old package is uninstalled. Review [that formula](https://github.com/HughLee824/homebrew-tap/blob/main/Formula/agentsoma.rb); if you trust it, explicitly grant trust to that formula only and retry:

```sh
brew trust --formula HughLee824/tap/agentsoma
brew install HughLee824/tap/iphone-use
```

This persistently trusts the one formula; it does not install the old package or require whole-Tap trust. If you do not want to grant it, use the checksum-verified manual Release installation.

## Maintainers

After publishing a stable GitHub Release in `HughLee824/iphone-use`, run **Actions → Update iPhone-use** on `main` with its version, without the leading `v`.

The workflow rejects draft and prerelease versions, checks the archive checksum, CLI/Runner file manifest and source commit against the release tag, and regenerates the formula from that tag's source. Only an exact match with the release's `iphone-use.rb` is committed to this Tap's `main`. The workflow uses this repository's `GITHUB_TOKEN`; no cross-repository write token is needed. Repeating the same version is a no-op. Do not edit the URL and SHA-256 independently.

Formula generation and the workflow template are maintained in [iPhone-use's packaging directory](https://github.com/HughLee824/iphone-use/tree/main/packaging/homebrew-tap). Sync template changes deliberately; normal formula updates only change `Formula/iphone-use.rb`.

MIT licensed; see [LICENSE](https://github.com/HughLee824/iphone-use/blob/main/LICENSE).
