# Codex: execute and display in one call

With `functions.exec` exposing `tools.exec_command`, use the start block for each selected CLI command. It prints completion/action facts and **displays an attached successful screenshot in the same invocation**, including `text-prepare`, `text-finish` and actions whose outcome is `unknown`. Inspect the emitted image before selecting the next action; do not separately call `view_image` or `observe` when it is already present.

## Start

Change `argv` to the command: one literal string per argument, using the resolved executable and actual session/reference values. Keep the shell quoting, result storage and image branch intact. Example arguments after the executable: `["--session", "SESSION", "tap", "oN", "--x", "X", "--y", "Y", "--observe", "--agent-output"]`. Use supported options only.

```javascript
const argv = ["iphone-use", "devices"];
const cmd = argv.map(arg => "'" + arg.replace(/'/g, "'\\''") + "'").join(" ");
const result = await tools.exec_command({
  cmd,
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

Shell quoting preserves user quotes, dollar signs, backticks and newlines. `JSON.stringify` is not shell quoting; shell operators in `argv` are literal arguments. For isolated configuration, prefix `argv` with `"/usr/bin/env", "IPHONE_USE_CONFIG_DIR=/absolute/path"`; there is no `--config` option. Use the execution tool's stdin/file mechanism for `--stdin`.

If a tool permission error or CoreDevice diagnostic requires host execution, use the tool's supported `sandbox_permissions: "require_escalated"` and `justification` consistent with active policy and authorization. These are tool options, not CLI arguments. Do not request elevation speculatively.

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
