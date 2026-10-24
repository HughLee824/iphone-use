# Contributing to iPhone-use

Keep changes focused and behavior explicit. Discuss substantial architecture or public-interface changes in an issue before implementation. Use [private vulnerability reporting](SECURITY.md) for security-sensitive findings.

## Development and validation

Read the [architecture](docs/architecture.md) and [testing guide](docs/testing.md). Use full Xcode 27 for native builds, Python 3.9+ and Node.js 22+. The pinned SwiftLint release and checksum live in [scripts/swiftlint.json](scripts/swiftlint.json).

```sh
python3 scripts/install-swiftlint.py
python3 scripts/check.py
```

The installer writes only under `.build/tools`; it does not replace a global installation. The check accepts either this local binary or an installed binary with the exact pinned version. Update the version and verified official archive checksum together in a dedicated tooling PR.

`python3 scripts/check.py --suite quick` runs portable documentation, tooling, plugin and Node checks. `--suite native` runs SwiftLint, CLI builds, both Swift suites, Objective-C runtime tests, Python integration tests and the unsigned Runner build. The default runs both suites. CI keeps the required `test` gate dependent on successful quick and native checks; a quick-only local run is not full device-free acceptance.

For device-facing changes, also validate the affected workflow with the exact CLI and explicitly installed Runner under test. Report actual commands, outcomes, skips and unverified cases. Do not infer device acceptance from a build, screenshot capture or a successful input receipt. Never replay uncertain input merely to make a test pass.

## Branches, commits and pull requests

Use short-lived branches from `main`, such as `fix/runner-focus` or `docs/install-guide`; automated Codex work uses `codex/…`. Submit a PR and use squash merging. Do not force-push `main`, rewrite published tags or replace published assets. A release remains an explicit maintainer operation, never a side effect of an ordinary merge.

Use this format for PR titles and final commits on `main`:

```text
type(scope)!: summary
```

- Types: `feat`, `fix`, `refactor`, `perf`, `docs`, `test`, `build`, `ci`, `chore`, `style`.
- Scope is optional and describes the affected area, such as `cli`, `core`, `runner`, `runner-support`, `native`, `preview`, `plugin` or `release`.
- Write a concrete English imperative summary. Keep the complete title within 72 characters; do not end it with a period. Avoid titles such as “update” or “fix bug”.
- Use `!` for an incompatible change. Explain the impact and migration in the PR body under `BREAKING CHANGE:`.
- Keep one coherent purpose per commit/PR, including its tests and necessary documentation. Separate unrelated formatting or generated asset changes. Development commits may be reorganized before squash merging; CI validates the PR title, not every intermediate commit.

Examples:

```text
fix(runner): preserve target identity during text input
docs: clarify installation prerequisites
refactor(core): separate session storage
feat(cli)!: require explicit session selection
```

The PR description should explain the concrete problem, resulting behavior, verification and remaining limitations. The template provides these prompts. Resolve review conversations and pass required checks before merging. The single-maintainer workflow does not require an impossible self-approval; obtain independent review when another maintainer is available, especially for signing, release and input-safety changes.

## Source ownership and generated files

Edit `skills/iphone-use/`, then run `python3 scripts/sync-plugin.py`. Do not edit its generated copy in `plugins/iphone-use/skills/` or the generated repository package manifest directly. Plugin-specific manifests and adapters remain in `plugins/iphone-use/`; the portable installer remains in `packages/iphone-use-skill/`.

Before releasing changed plugin/skill content, choose the next shared distribution version and run:

```sh
python3 scripts/set-plugin-version.py X.Y.Z
```

This updates the three plugin manifests, portable installer manifest and workflow version, then regenerates distribution copies. It does not publish, create tags, update the CLI version or query npm. Existing consistency checks still run; registry availability is checked by the release workflow.

## Versions and release notes

CLI and plugin/portable-skill distributions have independent versions. The Runner ships with its matching CLI. RunnerSupport is an internal shared module, not an independently published SDK.

Use patch releases for compatible fixes, minor releases for compatible capabilities, and major releases for incompatible changes after 1.0. While a channel is below 1.0, incompatible changes require a minor increment and explicit upgrade instructions. Do not choose a version mechanically from a commit prefix. Protocol changes require matching CLI/Runner validation and release notes.

Use GitHub Releases for CLI changes and the corresponding release PR plus publication workflow record for npm/plugin changes. Describe user-visible behavior, compatibility, upgrade steps and actual verification. Do not maintain a second chronological changelog with duplicate facts. Previously published artifacts remain immutable; publish a new version to correct them.

Follow [CLI/Runner release procedures](docs/release-setup.md), [plugin publication](docs/public-access-release.md) and [portable skill publication](docs/skill-release.md). Repository protection and channel configuration are documented in [maintenance](docs/maintenance.md).

## Files, documentation and evidence

Follow `.editorconfig`, `.gitattributes` and SwiftLint. Keep existing local style when changing Python or JavaScript; do not reformat unrelated code. New Swift files belong in the appropriate responsibility directory; keep generated build output and signing material out of Git.

Public documentation contains current contracts, reproducible procedures and curated examples. Keep both README entry points aligned and link to the owning guide instead of duplicating long instructions. Put investigations, raw device captures and personal notes under ignored `.local/`. Reusable test fixtures must be sanitized and work in a clean checkout. See the [documentation policy](docs/README.md#what-belongs-here).
