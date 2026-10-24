# Observation fixtures

`Observations/app.json` and `Observations/system-alert.json` contain selected AX attributes recorded from a controlled iPhone-use test app and its system notification prompt. They are regression inputs, not examples of the public CLI response format.

The fixtures preserve node order, parent relationships, geometry, labels, and values. Developer bundle IDs are replaced with `com.example.iphone-use.fixture`, timestamps use fixed example values, and local paths, request/session IDs, process metadata, and the original response envelope are removed.

`Package.swift` explicitly copies the two JSON inputs into the root of the test resource bundle, alongside the selected NativeText PNGs. README files are excluded, and this directory is not copied wholesale. `observationFixture` loads the JSON through `Bundle.module`, supplies the current observation metadata, and generates a synthetic PNG with `screenPNG()`. No physical device, original screenshot, local experiment, or documentation file is required.

Keep fixture data small and sanitized. Changes to node order or attributes should reflect an intentional regression case because tests exercise specific captured nodes.
