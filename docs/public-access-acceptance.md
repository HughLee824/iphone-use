# Public access acceptance — 8 September 2026

## Website repository split

Later on 8 September, website code and its two existing commits were extracted into the independent `HughLee824/agentsoma-website` repository (renamed to `HughLee824/iphone-use-website` on 11 October 2026). The pre-existing empty private repository was reused with its visibility preserved. Website tests and build checks now run separately on Ubuntu; [the first website CI run](https://github.com/HughLee824/iphone-use-website/actions/runs/34215374385) passed for commit `2450df4dde28ab58289d29d87314f5ce52ed7848`.

Cloudflare Workers Static Assets now serves the public website at **[agentsoma.dev](https://agentsoma.dev)** and `www.agentsoma.dev`. The first production deployment used website commit `18e42e8f41445f9a8c3dd87630a0e9a49aa632bb` and Worker version `d09c9ea3-3bf5-4a6a-a1e5-a165e9e3edb3`. Both HTTPS homepages returned 200, an unknown path returned 404, and all 13 deployed static files matched the local build byte for byte. Browser checks on the new host verified loaded fonts and images, desktop and narrow layouts, client selection and copy feedback.

The new repository owns its pinned Wrangler dependency, build checks and custom-domain configuration. Cloudflare Workers Builds is connected to its `main` branch; non-production builds are disabled. Before the first build, the dedicated token was narrowed to Workers Scripts edit and Account Settings read for the deployment account, User Details and Memberships read, and Zone read plus Workers Routes edit restricted to `agentsoma.dev`. Unrelated storage, database, AI, email and certificate permissions were removed. The original public Sites URL remains available.

Pushing website commit `3b8de7773613212b9d3a56c05ce3cb18dc54c4d4` triggered [a successful website CI run](https://github.com/HughLee824/iphone-use-website/actions/runs/34222283600) and Cloudflare build `eb21008f-24e9-40fa-9217-55079f3c4a5d`. The Cloudflare build used the narrowed token, ran the tests, all seven documentation-link checks and the static build, then deployed Worker version `2f35c82f-c4b3-462a-b560-87377f96edde` successfully. The production deployment showed this version receiving 100% of traffic. Both public homepages still matched the current build and returned 200; an unknown path returned 404.

The main repository's entry links and plugin homepage now use `https://agentsoma.dev`. Plugin **0.1.3** was published in commit `7596e03cc1d940c254775b0c800f0c0ab654d82c`; [its complete CI run](https://github.com/HughLee824/AgentSoma/actions/runs/34220545790) passed. From outside the source checkout, both Codex and Claude Code upgraded from public 0.1.2 to 0.1.3 using the documented commands. All nine files in each installed package matched the published source, and both bundled preflight scripts passed. This patch updates homepage metadata and the workflow version; device operations remain deferred.

The dated evidence below describes the original public-access delivery and is preserved as historical evidence.

## Original delivery

The [public website](https://agentsoma.hughlee824.chatgpt.site), client marketplaces, installation guides and build checks are delivered. **The two-client physical iPhone task remains pending:** the device was unavailable and the user requested completing the remaining deliverables first.

## Published scope

| Item | Evidence |
| --- | --- |
| Repository implementation | `f14dcc86035c08fcc81ca23eda780641d3936bc6` on public `main`. |
| Website | Public HTTPS access verified without authentication; page, scripts, fonts and both reviewed images returned 200; an unknown path returned 404. |
| Website source | Sites version 2, source commit `bb4fb3cee7096cc68bfa7eaac800fec0d0f74fdf`, containing only the static site source. |
| Plugin | `agentsoma@agentsoma` version **0.1.2**, distributed from `HughLee824/AgentSoma` in both clients. |
| CLI | Existing public Homebrew **0.1.0**. No new CLI release was created for this stage. |
| CI | [Complete successful run](https://github.com/HughLee824/AgentSoma/actions/runs/34213017810): Swift, Python, Node, unsigned Runner build, plugin archive, website build and artifact upload. |

## Public client installation and upgrades

Both tests ran outside the source checkout. Each client registered the public Git repository as its marketplace, then updated its installed plugin. An initial controlled local **0.1.0 → public 0.1.1** transition was followed by a genuine **public 0.1.1 → public 0.1.2** upgrade. The local 0.1.0 test package was never described as an earlier public plugin release.

| Client | Fresh-session evidence |
| --- | --- |
| Codex CLI 0.146.0 | Loaded `~/.codex/plugins/cache/agentsoma/agentsoma/0.1.2/skills/agentsoma/SKILL.md`, reported workflow 0.1.2, read the Codex adapter and ran the bundled preflight successfully. |
| Claude Code 2.1.250 | Loaded `~/.claude/plugins/cache/agentsoma/agentsoma/0.1.2/skills/agentsoma/SKILL.md`, reported workflow 0.1.2, read the Claude adapter and ran the bundled preflight successfully. |

All nine files in each installed plugin matched the published package. Preflight found CLI 0.1.0, full Xcode and action `--observe` support. These sessions intentionally issued no device discovery, connection, setup or input commands.

The test Mac's Codex CLI could not parse its existing `features.context_management` table, and its configured GPT-6-Astra model required a newer CLI. The verification command used a temporary `features.context_management=false` override and GPT-5.5 at low reasoning effort. The global client configuration was preserved. This demonstrates plugin loading on that compatible test combination, not successful use of the incompatible default combination. Claude used its configured model and normal scoped tool permissions.

## Website and package verification

- Browser checks covered desktop and 320, 375, 414 and 768 CSS pixel layouts. Additional overflow checks covered 960, 1280 and 1920 pixels. Client tabs, arrow-key selection, install anchors and copy feedback worked.
- With JavaScript omitted, both client installation blocks remained visible. A local test fixture that rejected clipboard writes selected the exact command text and offered manual copying. The fixture was not deployed.
- Text and focus contrast were calculated. Fonts are served locally with their licenses. Real calculator captures are attributed to the separate CLI 0.1.0 verification on 7 September; they are not evidence of today's client task acceptance.
- Local checks passed: **97 Swift tests, 32 Python tests, 15 Node template tests**, unsigned Runner compilation, plugin/skill validators, relocatable reproducible ZIP checks and the static build.
- The downloaded CI artifact's SHA-256 matched GitHub's recorded digest. Its plugin ZIP/checksum and all 13 website files matched the validated local build byte for byte.

One [preceding CI run](https://github.com/HughLee824/AgentSoma/actions/runs/34212377831) failed two assertions in the existing CLI action/observation integration test. No CLI runtime code changed in this stage. A local 150-repeat run did not reproduce the failure; assertions were improved to include the actual response on future failures, and the subsequent complete CI run passed. The intermittent failure's root cause remains unconfirmed; no test retry or suppression was added.

The Draft release workflow now packages and verifies the plugin alongside future CLI releases. It was not dispatched to create another binary release during this stage.

## Remaining acceptance

When the phone is connected again, follow [the first-task guide](first-task.md) separately in Codex and Claude Code: discover the intended device, connect, discover/open Settings, read actual PNGs, navigate to General, verify the page, exercise a safe rejection/refresh path and disconnect with cleanup verified. Use the public installed plugin and preserve both successful and failed outcomes.

Fresh-Mac signing, free Personal Team provisioning/renewal and additional device/system combinations remain outside the verified scope. Raw client logs, device identifiers and local screenshots stay in ignored local evidence; no signing materials are part of the site or plugin.
