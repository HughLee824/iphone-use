# Portable agent adapter

Use this adapter in Cursor, OpenCode, and other clients without a dedicated adapter. Tool names below describe capabilities, not functions to invent. Use the actual tools and parameter schemas provided by the current client.

## Before connecting

The agent must have all of these capabilities in the environment connected to the iPhone:

- Execute the local CLI and collect complete stdout plus exit status. If execution yields a job/process handle, continue that same handle until completion; do not repeat the command to retrieve its output.
- Read a local PNG **as image content supplied to the model**. A multimodal model, a text-only file reader, OCR, a path, or a terminal's description of a PNG is not enough. If the client does not expose image reading, report the missing capability before connecting or sending input.
- Read the skill's supporting text files and keep the returned device session ID and execution context across tool calls.

Use the skill's installed directory as the resource base, independent of the current working directory. If multiple `iphone-use` entries are advertised, choose one source explicitly and report the duplicate; do not mix their adapters or versions in the same session. Installation checks cannot see organization-injected or remote skills, so inspect the current client's advertised catalog as well.

## Execute, read the image, then decide

Run one selected `iphone-use` command per execution. Parse the completed JSON even when its exit status is nonzero. Preserve the raw result if parsing fails. Do not use shell `&&` to gate image reading on successful input, and do not rerun an input because image reading or JSON parsing failed.

For an input with `--observe`, read the PNG at `observation.result.screenshot` when `observation.ok` is true. For a standalone `observe`, read the returned `result.screenshot`. Use the client's image reader on that exact file before deciding on another input. If the file is unreadable, fix image access or report the blocker; an extra input is not an image-reader retry. A screenshot with `stable=false` can still be usable; apply the shared observation rules.

Read `action.outcome` separately from `observation.ok`. `unknown` input may have taken effect. Keep task-owned device sessions separate from shell job handles; do not reconnect merely because the shell command was asynchronous.

Follow the client's normal permission flow. Keep the working executable, host, environment and approved execution context for subsequent commands, including cleanup. A remote/container shell cannot operate the Mac's phone by accessing a shared repository alone. Do not silently switch transport, model, tool permissions or control mode.

## Preview and cleanup

For a local Mac client, use `iphone-use --session SESSION preview` once: the CLI opens the Mac's default browser. Do not add another browser-open call. Follow the shared [preview lifecycle](live-preview.md), including the user's opt-out and task record. If the user explicitly chooses an in-client browser, use `--no-open` and that actual browser capability instead. A browser is optional for the agent; image reading is not.

Disconnect only this task's session and verify the cleanup response. Do not stop a session owned by another agent. If the device is busy, report it rather than taking over. Keep acceptance PNGs and receipts private and copy relevant evidence before subsequent actions rotate the observation cache.
