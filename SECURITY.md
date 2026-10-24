# Security policy

Report suspected vulnerabilities privately through [GitHub's vulnerability reporting form](https://github.com/HughLee824/iphone-use/security/advisories/new). Do not include exploitable details or private device content in a public issue or pull request.

Include the affected CLI/plugin version or source commit, macOS/Xcode/iOS versions, selected control mode, expected and observed behavior, and minimal reproduction steps. Remove device identifiers, session tokens, private screenshots, clipboard contents, signing profiles and credentials. Start with a sanitized description; arrange any necessary sensitive evidence within the private report.

Security fixes target the latest stable release of each distribution channel. Upgrade older releases before retesting; older versions do not have a separate backport commitment. Findings in unreleased source should identify the exact commit. Reports receive best-effort maintainer review; this project does not promise a response-time SLA.

For ordinary installation and usage bugs, use the public issue templates with sanitized evidence. For operational boundaries and known limitations, see [architecture](docs/architecture.md), [actions](docs/actions.md) and [local preview](docs/local-preview.md).
