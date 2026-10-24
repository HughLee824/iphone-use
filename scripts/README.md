# Engineering tools

Run `python3 scripts/check.py` from the repository root for the shared device-free checks. This is the stable orchestration entry point for local development, CI and release preparation. Tool implementations are grouped by responsibility:

| Directory | Responsibility |
| --- | --- |
| `checks/` | Documentation links and PR title policy. |
| `tools/` | Checksum-pinned Actionlint and SwiftLint installers and version pins. |
| `release/` | CLI/Runner archives, integrity verification and Homebrew formula generation. |
| `plugin/` | Plugin/skill synchronization, package construction, versions and publication verification. |
| `device/` | Explicit physical-device acceptance and observation utilities; never auto-run phone actions. |
| `device/text-probe/` | Disposable iOS acceptance app and its Xcode project. |
| [brand/](brand/README.md) | Isolated, pinned design-time dependencies and asset generation. |
| `tests/` | Python/Node regression suites and sanitized fixtures for engineering tools. |

Install check tools first:

```sh
python3 scripts/tools/install-actionlint.py
python3 scripts/tools/install-swiftlint.py
python3 scripts/check.py
```

`--suite quick` runs portable workflow/documentation/plugin checks; `--suite native` builds and tests the macOS/iOS code and acceptance tools. The native suite builds the probe without signing and runs ContactFaultHost only with `--help` and `--self-test`; hardware acceptance remains explicit. Outputs belong in ignored `.build/` or `.local/`.

Internal command paths were reorganized with their documentation, tests and workflows. Use the current paths in [contribution rules](../CONTRIBUTING.md), [testing](../docs/testing.md) and [release procedures](../docs/release-setup.md). Do not duplicate implementations or invoke archived tools from `.local/`. Brand dependencies remain separate from the generated root npm manifest.
