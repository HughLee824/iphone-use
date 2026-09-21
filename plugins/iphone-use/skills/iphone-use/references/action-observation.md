# Fallback: one action followed by observation

Use this Codex template for older CLIs whose action `--help` does not list `--observe`. Newer CLIs provide the same sequence through the `--observe` flag and return separate `action` and `observation` responses in one JSON object. Do not add `--observe` to this fallback's action array: it would perform another capture.

The fallback combines an already chosen `open`, `tap`, `swipe`, `type`, or `press` and its following observation into one orchestration call using existing commands. Read [the basic call templates](codex-calls.md) first for execution permissions and continuation handling.

Copy the block intact into `functions.exec`, changing only `session` and `action` to actual values. Each array entry is one literal argument. Apply any required, already-authorized host execution options in the single `exec_command` options object, so both commands use the same context. Do not use this template for an action awaiting user authorization, or add more input actions to it.

```javascript
const session = "SESSION_FROM_CONNECT";
const action = ["tap", "o1:e2"];
if (typeof session !== "string" || !session || !Array.isArray(action) ||
    !action.every(arg => typeof arg === "string") ||
    !["open", "tap", "swipe", "type", "press"].includes(action[0])) {
  throw new Error("Supply a session and one open/tap/swipe/type/press argument array");
}

async function command(argv) {
  const cmd = argv.map(arg => "'" + arg.replace(/'/g, "'\\''") + "'").join(" ");
  let output = "";
  let current;
  try {
    current = await tools.exec_command({cmd, yield_time_ms: 10000, max_output_tokens: 6000});
    while (true) {
      output += current.output ?? "";
      if (Number.isInteger(current.exit_code)) return {...current, output};
      if (!Number.isInteger(current.session_id)) {
        throw new Error("No exit code or continuation handle; command completion is unknown");
      }
      current = await tools.write_stdin({
        session_id: current.session_id, chars: "", yield_time_ms: 10000, max_output_tokens: 6000
      });
    }
  } catch (error) {
    return {...current, output, toolError: String(error)};
  }
}

const execution = await command(["iphone-use", "--session", session, ...action]);
text({phase: "action", execution});
if (execution.toolError) {
  text({phase: "observation", skipped: "Resolve command completion first; do not replay the action"});
} else {
  let reply;
  try { reply = JSON.parse(execution.output); } catch {}
  const rejected = reply?.session === session && reply.ok === false &&
    reply.outcome === "not_dispatched" &&
    (reply.requiresObservation === false || reply.requiresObservation === undefined);
  if (rejected) {
    text({phase: "observation", skipped: "Not dispatched; no observation required by the response"});
  } else {
    text({phase: "observation", execution: await command(["iphone-use", "--session", session, "observe"])});
  }
}
```

## Read the two phases separately

- The `action` phase preserves the complete command output and exit code. The `observation` phase cannot overwrite the action's `completed`, `unknown`, or `not_dispatched` outcome.
- `completed` and `unknown` trigger one observation even when the action exits nonzero. Unrecognized output after a confirmed process exit also triggers observation conservatively; it is not relabeled as a successful or unexecuted action.
- A session-matching `not_dispatched` reply without a refresh requirement skips observation, preserving references when the host permits it. `requiresObservation=true` triggers observation, including target changes rejected before input.
- Pending commands are continued to completion, accumulating stdout chunks in order. Neither command is relaunched. If the execution tool fails or completion metadata is missing, the template stops; inspect its retained handle/output and resolve the original command before proceeding.
- If observation fails, retain the original action result, resolve the observation failure, and observe again when appropriate. Do not retry the action as recovery. Only a successful new observation provides fresh references. Read its PNG before another device input and verify the intended field values.
- If `functions.exec` yields a running cell ID, resume that cell with `wait`, keeping the user informed during longer waits. Do not rerun the block.

This is sequential orchestration, not an atomic device transaction. The app can change between commands, and another client can invalidate the new references. Existing host/Runner checks still apply. There is no automatic next input or business-result verification in this template.

## Evaluate the experiment

For each previously separate action/observation pair, the normal path becomes one orchestration invocation containing two CLI executions. Device calls, screenshot reading, and outcome verification remain necessary. Count orchestration calls, CLI executions, continuation polls, no-effect inputs, and final field correctness separately. Do not count synthetic execution timing as real model or device latency.

Run the maintained template tests from the repository with `node --test scripts/tests/test_agent_templates.mjs`. Node's built-in test runner is a development-only requirement; the example itself uses the calling tool's JavaScript runtime.
