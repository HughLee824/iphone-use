# Apple native backend

The `apple-native` backend implements standard mode using Apple CoreDevice services and the project's Swift/Objective-C adapters. It provides screenshots and HID input without starting XCTest. The current adapter is validated in the macOS/Xcode/iOS 27 environment; compilation deployment targets are not a compatibility guarantee. See [mode selection](control-modes.md) and [physical testing](testing.md).

## Transport and ownership

The default transport asks Apple's CoreDevice broker for named service sockets and retains its own paired-device tunnel assertion. It validates device identity and attaches Apple's RemoteXPC transport. It does not initiate pairing, alter system protections, or fall back to a different control backend.

The optional `--native-endpoint-inventory` is an explicit diagnostic route, not normal setup. It requires a recent Apple socket inventory and independently checks the service's device identity. Broker failure does not automatically select this route.

Device requests run serially in the session host. Connections, touch/key releases, clipboard transactions and media stops are scoped to resources owned by that session. Unconfirmed input or release remains uncertain; cleanup cannot retrospectively prove delivery.

## Screenshots and input

Standard observations and input preflight use fresh CoreDevice PNGs plus display metadata. Preview/recording frames are not action observations. A video heartbeat or cached frame is not proof of a fresh screenshot. Coordinates come from each observation's screen-point rectangle and actual image dimensions, including any viewer resizing.

Native `open` acknowledges launch separately from foreground readiness. `connect` can establish an observation-only session: require `result.controlAvailable=true` before input and inspect capabilities and recovery. No AX tree, OCR, focus traversal or built-in planning model is involved.

Touch gestures use current observation/context checks and the [screen guard](screen-guard.md). HID send completion is a host fact, not a device effect acknowledgement, so a normally queued native input can return `unknown`. Inspect the attached image before deciding what to do next; never automatically replay.

## Keyboard and clipboard

`text-prepare` discovers one device-advertised CoreDevice keyboard. It does not create or remove a hardware keyboard service, change the input method or focus a field. Cleanup releases this session's keys and connections. Use the returned fresh image to confirm the editor and focus.

Standard `type` supports ASCII key reports and literal clipboard paste. Editing shortcuts request selection or caret movement; the host cannot prove their app-specific effect. Unicode/multiline paste uses a transaction that preserves the original clipboard in memory. `text-finish` restores it only while ownership still matches. Process crashes, lost replies and concurrent clipboard writers limit restoration guarantees.

Each pre-input stage takes one fresh Apple PNG against the original observation. A request-relative dispatch budget prevents stale in-flight work; it does not expire an unchanged baseline merely because the agent spent time reasoning. Explicit caret exclusions are narrow, bound to the original observation, and never inferred from later differences. See [text commands](actions.md#实验性原生文字输入) and the [native text guard](native-text-phase-matching.md).

Both modes also support explicit touch-paste staging without keyboard events; its [prepared outcome and cleanup contract](actions.md#纯剪贴板与触摸粘贴两种模式) differ from ordinary typing.

## Control diagnostics and recovery

Read `controlErrorCode`, `controlError`, `hidState`, `sessionClosing` and `recovery` independently of media health. A healthy video stream does not establish control readiness. An action rejected as `native_control_unavailable` may include a more specific cause in `result.controlErrorCode`.

| Cause | Expected response |
| --- | --- |
| `native_release_uncertain` / `native_input_uncertain` | Inspect the effect, close the owned session, then explicitly reconnect and observe; do not replay the old action. |
| `native_session_closing` | Let owned cleanup finish before reconnecting. |
| `native_contact_active` | Check the original pending operation; do not overlap input. |
| Startup/service/HID failure | Resolve the reported prerequisite; repeated connection attempts alone are not a repair. |
| `native_media_unhealthy` / `native_connection_lost` | Inspect current status and cleanup requirements; do not classify transport loss as an orientation mismatch. |
| Screen/field mismatch | Inspect the exact rejection image and select a new action from the visible state. |

Recovery includes `automaticReplayAllowed=false`. Local IPC response loss does not establish host exit or non-dispatch; check the original session. Error summaries retain sanitized underlying Apple reasons rather than replacing them with guessed authorization failures.

## Media and runtime limits

Explicit preview/recording starts an owned media connection in either control mode. Both share streaming, decoding, recording and cleanup code; Runner input still uses XCTest. Ownership conflicts fail rather than stopping another client's stream. See [preview](local-preview.md) and [recording](runner-recording.md) for freshness recovery, orientation changes, validation and resource limits.

Apple runtime/service interfaces are checked at their adapter boundaries but are not a stable public SDK contract. Unsupported shapes or signatures fail explicitly. Last-check-to-event races, app-defined shortcut behavior and transport uncertainty remain limitations. Test affected device paths after toolchain changes; host fakes alone cannot establish compatibility.
