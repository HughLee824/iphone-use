# DeepSeek Harness adapter

The `dsh-iphone-use` bundle registers the shared `iphone-use` skill. Use Harness's **bash**, **job_output**, **read**, and **read_image** tools; use the actual exposed schemas if the composition differs. The shell executor must run on the Mac connected to the iPhone, and the filesystem/image reader must access that same Mac's CLI output. A remote or container-only executor is not a local device connection.

## Execute and collect completion

Start one selected CLI command with `bash`, for example:

```json
{"description":"List connected iPhones","command":"iphone-use devices"}
```

Read stdout, stderr and the `[exit code: N]` marker. Harness adds status markers around CLI output; do not parse the whole tool message as a CLI JSON object. A nonzero exit can still carry an action result and a valid attached observation.

Keep the complete CLI result. Do not pipe it through `tail`, `head`, or a substring filter: this can remove the outcome, recovery hint and screenshot path. Prefer `--agent-output` on supported actions. For an action whose output may exceed the tool limit, save stdout and stderr separately and preserve the CLI exit status, using actual arguments in place of this example:

```sh
umask 077
result_dir="$(mktemp -d "${TMPDIR:-/tmp}/iphone-use-result.XXXXXX")" || exit 1
if iphone-use --session SESSION tap oN --x X --y Y --observe --agent-output >"$result_dir/reply.json" 2>"$result_dir/stderr.txt"; then
  status=0
else
  status=$?
fi
cat "$result_dir/reply.json"
cat "$result_dir/stderr.txt" >&2
printf '\niphone_use_result=%s\n' "$result_dir/reply.json"
exit "$status"
```

If displayed output is incomplete, use `read` on that saved result (continue through all pages) after the same job finishes; do not rerun the action. The saved stdout contains `agentSummary` when available. The CLI's `receipt` is the full raw reply, **not** a copy of that presentation: inspect `action.result.screenGuard` (or `result.screenGuard` for an unwrapped reply) there, rather than treating a missing `agentSummary` as missing guard evidence.

If the command returns a background job ID, collect that **same** job with `job_output` (`job_id`, and `wait: true` when blocked on completion). Combine its incremental output with the initial result. Read a reported spill file with `read` if output was truncated. Never rerun `connect`, `setup`, or an input command to recover output. The Harness job ID is distinct from the iPhone-use device session ID. A timeout or cancelled job does not prove device input was never dispatched.

Each `bash` call starts a fresh shell. Pass the actual `--session` on every device command, and repeat any task-specific environment prefix; do not rely on an earlier shell's `export`. Preserve the resolved CLI and working execution permissions throughout the session. Single-quote shell arguments, escaping a literal apostrophe as `'\''`; for long text use a literal UTF-8 file with `type --stdin` instead of interpolating text into shell code.

## Read screenshots as images

After `observe`, read its UI text and call **read_image** with `file_path` set to the returned absolute PNG path. Harness's **read** tool reads text; it is not a substitute for **read_image**. A screenshot path or base64 string alone is not visual input.

After an action with `--observe`, check `action.outcome` separately from `observation.ok`. When the latter is true, read `observation.result.text` and call:

```json
{"file_path":"ABSOLUTE_SCREENSHOT_PATH_FROM_OBSERVATION"}
```

Inspect that image before choosing another action, including when the action exits nonzero, reports `unknown`, or returns `screen_changed / not_dispatched`. A rejection frame is a fresh visual decision point, not permission to reuse old coordinates. If image loading fails, retry only the image read. If no valid observation was returned, obtain a new `observe` instead of repeating the input. Only older CLIs without `--observe` need a separate observation; do not chain `action && observe`.

For visibly continuous video motion, follow the shared screen-guard rules: a safe fixed control with a separate recognizable page anchor may use `--dynamic-target` plus `--dynamic-anchor`, even when the video cannot fit within the 25% `--ignore-rect` limit. Read `validationScope`, `dynamicMatches` (target, anchor) and `accepted` together; whole-screen motion is diagnostic in explicit dynamic scope. A changed-pixel bounding rectangle is not the changed-pixel area. Verify the returned image even after accepted input, and never use this reduced scope for submissions, purchases or destructive actions.

If `read_image` is missing or refuses image input, report the missing composition/model capability before selecting screen targets. Do not silently switch models, install tools, or replace screenshot verification with OCR.

## Preview and permissions

Follow the shared [live-preview lifecycle](live-preview.md). On the first successful task-owned connection, run `preview` once; the CLI opens the Mac default browser. Do not issue a second browser-open call. Honor explicit opt-out and retain the session's attempt/URL record across turns. Disconnect cleans up the owned preview service.

Use the normal Harness approval flow after an actual permission denial, with the `sandbox_permissions` values advertised by its tool and a concrete `justification`. Do not copy Codex's permission enum, change profile-wide sandbox settings, or retry an uncertain device input. For CoreDevice discovery failures, follow the shared bounded diagnostic and preserve the working execution context on later calls. If filesystem policy prevents reading the screenshot, resolve that access through the supported client flow; a successful shell call does not grant image-reader access.

For standard text, follow [native text](native-text.md). Use `--agent-output` only on supported commands, and read the private receipt only when the summary and PNG leave a concrete question. Finish by disconnecting this task's session and checking cleanup.
