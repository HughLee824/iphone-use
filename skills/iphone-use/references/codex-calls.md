# Codex: execute and display in one call

With `functions.exec` exposing `tools.exec_command`, use the start block for each selected CLI command. It prints completion/action facts and **displays an attached successful screenshot in the same invocation**, including `text-prepare`, `text-finish` and actions whose outcome is `unknown`. Inspect the emitted image before selecting the next action; do not separately call `view_image` or `observe` when it is already present.

After connect, apply the shared [live-preview lifecycle](live-preview.md) before the first app observation/input. Run `preview --no-open` through this adapter, using the same CLI/environment/permissions as connect.

After successful completion, open `result.url` **once in the Codex built-in browser**. Use the exposed in-app browser capability (for example `cua.createBrowserTab("iab", url, {visible: true})`) following its tool instructions; retain its tab handle for cleanup. If only `mcp__codex_app__open_in_codex` is available, use `target: {type: "browser", url: result.url}`. A `queued` result is pending, not proof that a page is visible; do not issue a second open request.

Choose one mechanism, never both. Record the opening attempt before the call and keep the returned tab ID when available. If no built-in browser tool is exposed, provide the URL without opening a system browser. Do not run plain `preview` or shell `open` as a fallback. Preserve the per-session attempt/URL record across pending commands and turns. Explicit opt-out skips preview, and disconnect cleans up the owned service.

## Start

Keep the resolved CLI, configuration/state paths and working execution context for the entire device session. For an explicitly supplied prerelease, run `preflight.sh --candidate` with `IPHONE_USE_CLI` set to that binary; a plain preflight deliberately rejects prereleases.

When task isolation is requested, create a short private runtime directory once (for example `umask 077; mktemp -d /private/tmp/iu.XXXXXX`, then create `config` and `state` inside it). Use the returned paths in the environment prefix below on **every** CLI call. Keep long evidence paths separate: the state root plus `/s` + 32 hex digits + `/ipc.sock` must fit within 103 UTF-8 bytes. Normal tasks can retain the CLI defaults.

Change `argv` to the command: one literal string per argument, using the resolved executable and actual session/reference values. Keep the shell quoting, result storage and image branch intact. Example arguments after the executable: `["--session", "SESSION", "tap", "oN", "--x", "X", "--y", "Y", "--observe", "--agent-output"]`. Use supported options only.

```javascript
const argv = ["iphone-use", "devices"];
const cmd = argv.map(arg => "'" + arg.replace(/'/g, "'\\''") + "'").join(" ");
const result = await tools.exec_command({
  cmd,
  ...(load("iphone-use.execution-context") ?? {}),
  yield_time_ms: 10000,
  max_output_tokens: 6000
});
store("iphone-use.execution", result);
if (!Number.isInteger(result.exit_code)) {
  text(result);
} else {
  let reply;
  try { reply = JSON.parse(result.output); } catch {}
  text(reply ? {exit_code: result.exit_code, ...reply} : result);
  if (reply?.observation?.ok === true && reply.observation.result?.screenshot) {
    const screenshot = await tools.view_image({path: reply.observation.result.screenshot});
    image(screenshot.image_url);
  }
}
```

Shell quoting preserves user quotes, dollar signs, backticks and newlines. `JSON.stringify` is not shell quoting; shell operators in `argv` are literal arguments. For isolated configuration/state, prefix `argv` with `"/usr/bin/env", "IPHONE_USE_CONFIG_DIR=/actual/short/config", "IPHONE_USE_STATE_DIR=/actual/short/state"`; there is no `--config` option. Use the execution tool's stdin/file mechanism for `--stdin`.

If a tool permission error or CoreDevice diagnostic requires host execution, compare `devices` once using the tool's supported `sandbox_permissions: "require_escalated"` and a specific `justification`, consistent with active policy and authorization. These are tool options, not CLI arguments. Do not request elevation speculatively. If that approved discovery completes successfully, store the working context **before connect**:

```javascript
store("iphone-use.execution-context", {
  sandbox_permissions: "require_escalated",
  justification: "Use the host execution context established by successful device discovery for this authorized iPhone task."
});
```

The start block then requests the same context for connect and subsequent device commands, including disconnect. Each request remains subject to tool approval; this record is not an approval bypass. If the execution runtime resets, restore the context from the successful call's evidence instead of silently returning to the failing sandbox. A rejected approval is a blocker, not grounds to switch execution mechanisms.

Correcting an omitted candidate flag, an overlong state path or a diagnosed execution-context mismatch before device input is not replaying a phone action. After resolving the concrete cause, one corrected startup attempt is appropriate unless the user prohibited retries. Before retrying a failed connect, inspect this task's state directory for startup/exit facts and a possibly live host; no returned session ID does not prove no host was created. Do not reconnect over an unresolved live session. If the corrected attempt fails the same way, stop and report the evidence. An unknown input outcome still never permits automatic replay.

When acceptance evidence is requested, preserve command results and relevant `startup-error.json`, `host.log`, `config.json` and `exit.json` from owned state directories before cleanup. Verify owned-host termination before removing runtime state; do not delete another client's state. Use recorded tool/CLI timestamps for timing claims, not handwritten estimates.

## Continue only if pending

If `functions.exec` returns a running **cell ID**, resume with `functions.wait` first, never rerun the block. If the command returns a background **session_id**, use its actual numeric value below; this is not the iPhone-use device session. Continue until an exit code exists. Do not start another command while output is pending; it would replace the stored state. Keep waits short enough for progress updates.

```javascript
const sessionId = 12345;
const previous = load("iphone-use.execution");
if (previous?.session_id !== sessionId || Number.isInteger(previous.exit_code)) {
  throw new Error("Use the running command's execution session ID");
}
const result = await tools.write_stdin({
  session_id: sessionId,
  chars: "",
  yield_time_ms: 10000,
  max_output_tokens: 6000
});
const execution = {...result, output: (previous.output ?? "") + (result.output ?? "")};
store("iphone-use.execution", execution);
if (!Number.isInteger(execution.exit_code)) {
  text(result);
} else {
  let reply;
  try { reply = JSON.parse(execution.output); } catch {}
  text(reply ? {exit_code: execution.exit_code, ...reply} : execution);
  if (reply?.observation?.ok === true && reply.observation.result?.screenshot) {
    const screenshot = await tools.view_image({path: reply.observation.result.screenshot});
    image(screenshot.image_url);
  }
}
```

Exit status is process completion, not task success. Read `action.outcome` and `observation.ok` separately. A nonzero action exit can still include a fresh screenshot; never use `action && observe` or repeat input to recover output. A wrapper syntax error before tool execution did not reach the device.

## Only if image reading failed

The command facts are printed and stored before image loading. If that loading failed, retry this reader, not the command. It performs no device operation. Failed/skipped observations have no fresh image; follow their error and reference validity.

```javascript
const execution = load("iphone-use.execution");
if (!Number.isInteger(execution?.exit_code)) {
  text({pending: true, execution});
} else {
  const reply = JSON.parse(execution.output);
  text({exit_code: execution.exit_code, ...reply});
  if (reply.observation?.ok === true) {
    const screenshot = await tools.view_image({path: reply.observation.result.screenshot});
    image(screenshot.image_url);
  }
}
```

Use `--agent-output` when available; consult its private full receipt only for a concrete question. A displayed image still needs visual judgment: `completed` is not task success, and `unknown` never authorizes automatic replay.
