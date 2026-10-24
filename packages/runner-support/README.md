# IPhoneUseRunnerSupport

Repository-local Swift package shared by the macOS host and the iOS Runner.
It is statically linked into both products and has no external package dependencies,
resources, XCTest imports, device connections or dependency on IPhoneUseCore.

The package owns reusable AX path/identity algorithms, one-shot text transaction
orchestration, geometry and image guards, frame stability, and the scoped XCTest
UserDefaults wrapper. Actual element access, runtime adapters and event delivery
remain in the Runner; host sessions, observation caches and device transport remain
in Core. Public declarations exist for those consumers, not as a separately
versioned SDK. Keep pixel/validation helpers internal or private when consumers do
not need them.

Extraction preserves wire fields, guard thresholds, deadlines, reference consumption,
and input dispatch counts. No action is retried by this package; only the existing
bounded read-only geometry convergence may repeat.

Run standalone tests with:

```sh
swift test --package-path packages/runner-support --jobs 2
```

Run the full repository check with `python3 scripts/check.py`. It also tests Core,
builds the CLI and unsigned iOS Runner, and validates tooling. Root `swift test`
alone does not execute this dependency package's tests. Tests needing Core fixtures
or host integration stay in `Tests/IPhoneUseCoreTests/RunnerSupport/`.
