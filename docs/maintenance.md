# Repository maintenance

[CONTRIBUTING.md](../CONTRIBUTING.md) defines the contributor-facing Git, validation and version policy. This page describes the settings needed to enforce it. GitHub settings are external state: verify them after changing repository ownership, permissions or workflow names.

## Main branch and pull requests

The `Protect main: PR and CI required` ruleset targets `main` and the default branch. It blocks deletion and non-fast-forward updates, requires a pull request, resolved review conversations and up-to-date required checks, and has no bypass actors. Required approval count is zero for the single-maintainer workflow; this does not waive review when another maintainer is available.

Allow squash merging only and use the PR title as the squash commit title. The `quick` CI job validates titles on PR creation, title edits and source updates. Its input is read from the event JSON, never inserted into shell code. Development commit titles remain unrestricted.

Keep the required GitHub Actions status context **`test`**. It is an always-run final gate: both `quick` and `native` must report `success`. A failed, cancelled or skipped upstream job must fail the gate. Do not replace it with a job that is simply skipped when prerequisites fail; skipped status checks can satisfy branch requirements. Coordinate any context rename with the repository ruleset.

The quick job runs on Linux and native checks run on the Xcode macOS image. The default local `python3 scripts/check.py` runs both groups. Draft releases also use the full entry point; publication workflows require successful push CI for the exact `main` commit. A local pass does not establish a cloud workflow run.

## Release and reporting settings

- Enable GitHub private vulnerability reporting, which provides the route linked from [SECURITY.md](../SECURITY.md).
- Protect `v*` tags against update and deletion while allowing new version tags. Release workflows may create a new tag but must never replace one. Repository administrators should treat published release assets as immutable; tag rules alone cannot prevent asset replacement.
- The `npm` environment limits publication to the intended branch. Preserve its existing branch policy and OIDC trusted-publisher configuration. Do not require an unavailable independent approver for a single-maintainer repository. Reassess approval requirements when maintainers are added.
- Do not automatically merge dependency-update PRs or publish packages from them. Monthly Dependabot updates cover GitHub Actions and the root Swift package; the other local package currently has no external Swift dependencies.

## Tool versions and generated content

Actionlint is pinned with platform-specific archive SHA-256 values in `scripts/actionlint.json`. Install it with `python3 scripts/install-actionlint.py`; the quick suite requires that checkout-local version. It checks the repository and Homebrew template workflows. Upgrade the version and official checksums together.

The SwiftLint pin includes an official portable-archive SHA-256 in [scripts/swiftlint.json](../scripts/swiftlint.json). Install with `python3 scripts/install-swiftlint.py`; it downloads with macOS system `curl` over verified HTTPS, verifies the archive before running the binary and checks the reported version. CI and local checks reject another version. Installation is checkout-local; do not change a user's global Homebrew tool to match CI.

For a SwiftLint upgrade, inspect the official release, update both fields, then run strict lint and the full checks. Do not disable rules or mass-format unrelated files merely to make the upgrade pass. GitHub Actions are pinned by commit; review dependency PRs before updating those pins.

Use `python3 scripts/set-plugin-version.py X.Y.Z` to change the shared plugin/skill distribution version. It validates every source before writing, rejects drift and downgrades, and regenerates package/skill copies. It does not modify the CLI's independent release version or publish anything. If interrupted during writes, inspect the diff and restore a consistent version before rerunning. Publication preflight remains responsible for checking whether a version already exists in the registry.
