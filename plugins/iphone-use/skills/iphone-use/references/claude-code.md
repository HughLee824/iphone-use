# Claude Code adapter

Use the installed `iphone-use:iphone-use` skill, invoked as `/iphone-use:iphone-use`, and the client's **Bash**, **Read**, and command continuation tools. The shared SKILL.md defines device routing, reference validity, action outcomes, and task verification.

## Execute one command and collect completion

Use Bash with one selected CLI command, for example:

```sh
iphone-use devices
```

Keep Bash's stdout, stderr, exit code, and any background task ID. If Bash runs the command in the background, collect its original result with **TaskOutput** (or the continuation tool named by the current client). If it returns an output-file path, Read that path as directed by Bash and confirm the task has finished. Partial output is not completion. Never repeat `connect`, `setup`, or an input command just to obtain its output. The Bash task ID and iPhone-use's `session` are different identifiers.

Use `iphone-use --session 'SESSION_FROM_CONNECT' …` for subsequent commands. Replace example sessions and references with actual results. Shell-quote each argument: a literal apostrophe inside a single-quoted argument is written as `'\''`. Never place user text containing `$()`, backticks, quotes, or newlines into interpolated double-quoted shell code. For long text, use a literal UTF-8 file with `type --stdin`.

## Read screenshots as images

After `observe`, read both the AX text and the file identified by `screenshot`. Call **Read** with that absolute PNG path; Claude Code displays PNG files as images. Reading only stdout, the path string, file metadata, or base64 text does not read the screen. Do not use a desktop screenshot or browser tool as a substitute.

After an already chosen action with `--observe`, read the single JSON object:

```sh
iphone-use --session 'SESSION_FROM_CONNECT' tap 'CURRENT_OBSERVATION:ELEMENT' --observe
```

`action.outcome` and `observation.ok` are separate. When `observation.ok` is true, read `observation.result.text` and call **Read** on `observation.result.screenshot`, including when the command exits nonzero. Use its fresh references for the next action only after checking the image. If observation failed or was skipped, recover through `observe`, never by replaying the action.

For CLIs without `--observe`, run the selected action, collect its exit code and JSON, then separately `observe` after `completed`, `unknown`, or a rejection requiring refresh. Do not use `action && observe`: a nonzero action exit can still mean the input took effect. The JavaScript fallback in `action-observation.md` is for Codex's orchestration tool, not Bash.

## Permissions and failure handling

Keep normal client permissions. Installing a skill does not authorize arbitrary shell commands or grant macOS/iPhone permissions. Follow the shared CoreDevice diagnostic when sandboxed discovery fails; resolve the concrete access failure through the client's supported approval flow. Do not disable sandboxing globally, reset device services, or conclude the phone is disconnected from a timeout alone.

After `unknown`, inspect the attached observation (capture only if absent) and judge the actual state before choosing another input. On `not_dispatched`, follow `requiresObservation`. Preserve default screen guards and do not blindly retry. On completion or a recoverable failure, disconnect the session created for this task and check cleanup. Report any unresolved failure instead of claiming the task passed.

For standard text, follow [the native text workflow](native-text.md): reuse keyboard readiness and returned observations. When preflight reports support, add `--agent-output` on actions, `text-prepare` and `text-finish`; the private receipt retains full diagnostics. Do not Read the full receipt routinely when the summary and PNG answer the task.
