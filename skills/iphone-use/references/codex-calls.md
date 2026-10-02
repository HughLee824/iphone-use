# Fixed Codex call templates

Use these templates when `functions.exec` exposes `tools.exec_command` and `tools.write_stdin`. They run one command at a time; choose the next device action from its observed result. Other clients should use their native execution tool with the same completion discipline.

## Start a command

Change only the `argv` array for the intended CLI call. Every entry must be a string containing one literal argument. Keep the quoting expression and completion fields, including `session_id` and `exit_code`. Use the same resolved executable throughout the task. For isolated configuration, prefix the array with `"/usr/bin/env", "IPHONE_USE_CONFIG_DIR=/absolute/config path"`; do not invent `--config`.

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

For example, Runner text replacement uses these arguments in the same template (native text uses `oN` and a complete `--field-rect`, as described in [the native text workflow](native-text.md)):

```json
["iphone-use", "--session", "SESSION_FROM_CONNECT", "type", "o4:e21", "--mode", "replace", "--text", "版本发布事项讨论", "--observe"]
```

Use current session/reference values from actual results. Quotes, dollar signs, backticks, and spaces in user text stay literal under the template's shell quoting. Do not replace it with `JSON.stringify(argv)` as shell command text. Shell operators in the argument array are literal arguments, not pipelines; use the execution tool's supported stdin/file mechanism when `--stdin` is needed.

If a tool-level permission error or the CoreDevice diagnostic requires host execution, add the execution tool's supported `sandbox_permissions: "require_escalated"` and an appropriate `justification` to its options, following the active host policy and existing authorization. Do not treat that option as an iPhone-use CLI argument or request elevation speculatively.

## Continue the same command

When the result has a background `session_id`, use its actual numeric value below. This is **not** the iPhone-use session string. Repeat continuation only while the tool reports the same command is still running. These templates retain output chunks in `store` for the result reader; finish and read this command before starting another, which replaces that stored result.

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

If `functions.exec` itself reports a running cell ID, resume that cell with its `wait` tool first. Do not re-execute the original script. Keep individual waits short enough to provide progress updates.

## Interpret completion

- A background handle or partial stdout is pending work, even if stdout already contains a CLI path or some JSON. Do not relaunch the command.
- An exit code means that shell process ended. Read its output and any iPhone-use `outcome` together; exit code zero does not establish the user's business result.
- `unknown` means input may have happened. Inspect the attached successful observation before deciding what to do next; capture only if one is missing. Do not use `action && observe` as an unconditional recovery template: a nonzero action exit can still need observation.
- A JavaScript syntax error before the execution tool was called did not reach iPhone-use. Correct the wrapper. Do not classify it as a device failure.

## Recover image reading without another device command

The start/continuation templates print the reply and open an attached successful PNG in the same tool call, including for native `text-prepare` and `text-finish`. Do not run another reader if the image was already displayed. If image reading failed after command completion, use this recovery reader in `functions.exec`. It uses the accumulated output and does not issue device input. Read `action` and `observation` separately: an `unknown` action or a guard rejection can return top-level `ok: false` with a successful fresh observation. In that case the PNG still needs to be opened and checked alongside the returned text and references.

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

When preflight reports support, add `--agent-output` to actions and native `text-prepare`/`text-finish` to avoid printing repeated media diagnostics. The `receipt` retains the full response. Default output remains compatible with older clients.

A screenshot path in JSON does not mean the image was read. Inspect the emitted image and verify the intended UI result before another input. If parsing or image loading fails, retain the printed command/action facts and resolve that reading failure; do not replay the action. A failed or skipped observation supplies no fresh screenshot; follow its error and reference validity before proceeding.
