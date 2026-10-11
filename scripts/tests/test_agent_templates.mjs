import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import test from 'node:test';

const root = new URL('../../', import.meta.url);
const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor;
function blocks(path) {
  return [...readFileSync(new URL(path, root), 'utf8').matchAll(/```javascript\n([\s\S]*?)```/g)]
    .map(match => match[1]);
}
function sectionBlock(path, heading) {
  const document = readFileSync(new URL(path, root), 'utf8');
  const section = document.split(`## ${heading}\n`)[1]?.split('\n## ')[0];
  assert.ok(section, `Missing template section: ${heading}`);
  const code = section.match(/```javascript\n([\s\S]*?)```/)?.[1];
  assert.ok(code, `Missing JavaScript template: ${heading}`);
  return code;
}
const codexCalls = 'skills/iphone-use/references/codex-calls.md';
const start = sectionBlock(codexCalls, 'Start');
const resume = sectionBlock(codexCalls, 'Continue only if pending');
const readObservation = sectionBlock(codexCalls, 'Only if image reading failed');
const [combined] = blocks('skills/iphone-use/references/action-observation.md');
const session = 'test-session';
const observed = {exit_code: 0, output: 'observation=o2 refs=current\nscreenshot="/fixture/screen.png"\n'};
function memory(initial) {
  const values = new Map([['iphone-use.execution', initial]]);
  return {store: (key, value) => values.set(key, value), load: key => values.get(key)};
}
function reply(outcome, fields = {}) {
  return {exit_code: outcome === 'completed' ? 0 : 1,
    output: JSON.stringify({session, ok: outcome === 'completed', outcome, ...fields})};
}

async function run(executions, continuations = [], action = ['tap', 'o1:e2']) {
  const calls = [];
  const output = [];
  async function next(queue, kind, options) {
    calls.push({kind, options});
    assert.ok(queue.length, `Unexpected ${kind}: possible command replay`);
    const result = queue.shift();
    if (result instanceof Error) throw result;
    return result;
  }
  const code = combined
    .replace('const session = "SESSION_FROM_CONNECT";', `const session = ${JSON.stringify(session)};`)
    .replace('const action = ["tap", "o1:e2"];', `const action = ${JSON.stringify(action)};`);
  await new AsyncFunction('tools', 'text', code)({
    exec_command: options => next(executions, 'exec', options),
    write_stdin: options => next(continuations, 'resume', options)
  }, value => output.push(value));
  assert.equal(executions.length, 0);
  assert.equal(continuations.length, 0);
  return {calls, output};
}

test('basic template preserves literal shell arguments and the background handle', async () => {
  const values = ['', 'plain', 'two words', "O'Brien", '版本发布事项讨论', '$(printf SUBSTITUTED)',
    '`printf SUBSTITUTED`', '$HOME; exit 17', '"quoted" \\ path'];
  for (const value of values) {
    const pending = {output: 'partial', session_id: 42};
    const output = [];
    const state = memory();
    const code = start.replace('const argv = ["iphone-use", "devices"];',
      `const argv = ${JSON.stringify(['/usr/bin/printf', '%s', value])};`);
    await new AsyncFunction('tools', 'text', 'store', 'load', code)({exec_command: async options => {
      assert.equal(execFileSync('/bin/sh', ['-c', options.cmd], {encoding: 'utf8'}), value);
      return pending;
    }}, value => output.push(value), state.store, state.load);
    assert.strictEqual(output[0], pending);
    assert.strictEqual(state.load('iphone-use.execution'), pending);
  }
});

test('start preserves the discovered execution context across subsequent commands', async () => {
  const state = memory();
  const context = {sandbox_permissions: 'require_escalated', justification: 'Authorized host context'};
  state.store('iphone-use.execution-context', context);
  const execute = new AsyncFunction('tools', 'text', 'store', 'load', start);
  for (let command = 0; command < 2; command++) {
    const result = {exit_code: 0, output: 'done'};
    await execute({exec_command: async options => {
      assert.equal(options.sandbox_permissions, context.sandbox_permissions);
      assert.equal(options.justification, context.justification);
      return result;
    }}, () => {}, state.store, state.load);
    assert.strictEqual(state.load('iphone-use.execution'), result);
    assert.deepEqual(state.load('iphone-use.execution-context'), context);
  }
});

test('basic continuation preserves pending, failed, and successful results', async () => {
  for (const result of [{output: 'partial', session_id: 12345}, reply('unknown'), reply('completed')]) {
    const output = [];
    const state = memory({session_id: 12345, output: 'earlier chunk'});
    let calls = 0;
    await new AsyncFunction('tools', 'text', 'store', 'load', resume)({write_stdin: async options => {
      calls++;
      assert.equal(options.session_id, 12345);
      assert.equal(options.chars, '');
      return result;
    }}, value => output.push(value), state.store, state.load);
    assert.equal(calls, 1);
    assert.deepEqual(output[0], Number.isInteger(result.exit_code)
      ? {...result, output: 'earlier chunk' + result.output} : result);
    assert.deepEqual(state.load('iphone-use.execution'), {...result, output: 'earlier chunk' + result.output});
  }
});

test('continuation rejects stale or completed handles before polling', async () => {
  for (const previous of [undefined, {session_id: 42}, {session_id: 12345, exit_code: 0}]) {
    const state = memory(previous);
    await assert.rejects(new AsyncFunction('tools', 'text', 'store', 'load', resume)(
      {}, () => {}, state.store, state.load), /running command/);
  }
});

test('observe reader opens successful captures even when the action fails', async () => {
  for (const outcome of ['completed', 'unknown', 'not_dispatched']) {
    const payload = {ok: outcome === 'completed', action: {outcome},
      observation: {ok: true, result: {screenshot: '/fixture/screen.png', text: 'fresh refs'}}};
    const output = [];
    const images = [];
    const execution = {exit_code: payload.ok ? 0 : 1, output: JSON.stringify(payload)};
    const state = memory(execution);
    await new AsyncFunction('tools', 'text', 'image', 'load', readObservation)({
      view_image: async options => {
        assert.equal(options.path, '/fixture/screen.png');
        assert.deepEqual(output, [{exit_code: execution.exit_code, ...payload}]);
        return {image_url: 'data:image/png;base64,fixture'};
      }
    }, value => output.push(value), value => images.push(value), state.load);
    assert.deepEqual(images, ['data:image/png;base64,fixture']);
  }
});

test('observe reader waits for full accumulated JSON and never repeats input', async () => {
  const payload = {ok: true, action: {outcome: 'completed'},
    observation: {ok: true, result: {screenshot: '/fixture/screen.png'}}};
  const json = JSON.stringify(payload);
  const state = memory();
  const output = [];
  const emit = value => output.push(value);
  await new AsyncFunction('tools', 'text', 'store', 'load', start)({exec_command: async () =>
    ({session_id: 12345, output: json.slice(0, 20)})}, emit, state.store, state.load);
  const reader = new AsyncFunction('tools', 'text', 'image', 'load', readObservation);
  await reader({}, emit, () => assert.fail('pending screenshot'), state.load);
  assert.equal(output.at(-1).pending, true);
  let images = 0;
  await new AsyncFunction('tools', 'text', 'store', 'load', 'image', resume)({write_stdin: async () =>
    ({exit_code: 0, output: json.slice(20)}), view_image: async () => ({image_url: 'fixture'})},
    emit, state.store, state.load, () => images++);
  assert.equal(images, 1); // No second reader or device observation is needed.
  assert.equal(state.load('iphone-use.execution').output, json);
});

test('failed observations or image loading preserve action facts without device calls', async () => {
  const reader = new AsyncFunction('tools', 'text', 'image', 'load', readObservation);
  for (const observation of [{ok: false, error: {code: 'capture_failed'}}, {skipped: 'not_dispatched'},
    {ok: true, result: {screenshot: '/missing.png'}}]) {
    const payload = {ok: false, action: {outcome: 'unknown'}, observation};
    const state = memory({exit_code: 1, output: JSON.stringify(payload)});
    const output = [];
    const reading = reader({view_image: async () => {throw new Error('image unavailable');}},
      value => output.push(value), () => assert.fail('unexpected image'), state.load);
    if (observation.ok) await assert.rejects(reading, /image unavailable/);
    else await reading;
    assert.deepEqual(output, [{exit_code: 1, ...payload}]);
  }
});

test('completed and unknown actions each get one new observation', async () => {
  for (const outcome of ['completed', 'unknown']) {
    const action = reply(outcome);
    const {calls, output} = await run([action, observed]);
    assert.deepEqual(calls.map(call => call.kind), ['exec', 'exec']);
    assert.ok(calls[0].options.cmd.includes("'tap' 'o1:e2'"));
    assert.equal(calls[1].options.cmd, "'iphone-use' '--session' 'test-session' 'observe'");
    assert.deepEqual(output, [{phase: 'action', execution: action}, {phase: 'observation', execution: observed}]);
  }
});

test('all supported input commands use literal arguments and the same session', async () => {
  for (const action of [['open', 'com.example.fixture'], ['swipe', 'o1:e2', '--direction', 'up'],
    ['type', 'o1:e2', '--mode', 'replace', '--text', "O'Brien $(printf WRONG)"],
    ['press', 'o1:e2', '--key', 'return']]) {
    const {calls} = await run([reply('completed'), observed], [], action);
    const literal = execFileSync('/bin/sh', ['-c', calls[0].options.cmd.replace("'iphone-use'", "'/usr/bin/printf' '%s\\0'")]);
    assert.deepEqual(literal.toString().split('\0').slice(0, -1), ['--session', session, ...action]);
  }
});

test('background chunks are accumulated before deciding whether to observe', async () => {
  const rejected = reply('not_dispatched');
  const {calls, output} = await run([{session_id: 42, output: rejected.output.slice(0, 12)}],
    [{session_id: 42, output: rejected.output.slice(12, 30)}, {...rejected, output: rejected.output.slice(30)}]);
  assert.deepEqual(calls.map(call => call.kind), ['exec', 'resume', 'resume']);
  assert.deepEqual(calls.slice(1).map(call => call.options.session_id), [42, 42]);
  assert.equal(output[0].execution.output, rejected.output);
  assert.equal(output[0].execution.exit_code, 1);
  assert.ok(output[1].skipped);
});

test('observation itself is continued without restarting either command', async () => {
  const {calls, output} = await run([reply('completed'), {session_id: 73, output: 'observation=o2 '}],
    [{exit_code: 0, output: 'refs=current\n'}]);
  assert.deepEqual(calls.map(call => call.kind), ['exec', 'exec', 'resume']);
  assert.equal(calls[2].options.session_id, 73);
  assert.equal(output[1].execution.output, 'observation=o2 refs=current\n');
});

test('confirmed rejection skips refresh unless the host requires observation', async () => {
  for (const requiresObservation of [undefined, false, true]) {
    const action = reply('not_dispatched', {requiresObservation});
    const {calls, output} = await run(requiresObservation ? [action, observed] : [action]);
    assert.equal(calls.length, requiresObservation ? 2 : 1);
    assert.deepEqual(output[0].execution, action);
    assert.equal(Boolean(output[1].execution), requiresObservation === true);
  }
});

test('unrecognized or mismatched replies cannot suppress observation or imply success', async () => {
  for (const action of [{exit_code: 1, output: 'truncated or invalid JSON'},
    {exit_code: 0, output: 'null'}, reply('not_dispatched', {session: 'other-session'}),
    reply('not_dispatched', {requiresObservation: 'invalid'})]) {
    const {calls, output} = await run([action, observed]);
    assert.equal(calls.length, 2);
    assert.deepEqual(output[0].execution, action);
  }
});

test('observation failures preserve the original action outcome and never replay input', async () => {
  for (const outcome of ['completed', 'unknown']) {
    for (const failure of [{exit_code: 1, output: '{"ok":false,"error":{"code":"capture_failed"}}'},
      new Error('observation execution tool unavailable')]) {
      const action = reply(outcome);
      const {calls, output} = await run([action, failure]);
      assert.equal(calls.length, 2);
      assert.deepEqual(output[0].execution, action);
      if (failure instanceof Error) assert.match(output[1].execution.toolError, /unavailable/);
      else assert.deepEqual(output[1].execution, failure);
    }
  }
});

test('uncertain command completion stops before observation and retains its handle', async () => {
  const {calls, output} = await run([{session_id: 42, output: 'partial'}], [new Error('continuation lost')]);
  assert.deepEqual(calls.map(call => call.kind), ['exec', 'resume']);
  assert.equal(output[0].execution.session_id, 42);
  assert.equal(output[0].execution.output, 'partial');
  assert.match(output[0].execution.toolError, /continuation lost/);
  assert.ok(output[1].skipped);
  for (const failure of [new Error('launch status unknown'), {output: 'no completion metadata'}]) {
    const stopped = await run([failure]);
    assert.equal(stopped.calls.length, 1);
    assert.ok(stopped.output[0].execution.toolError);
    assert.ok(stopped.output[1].skipped);
  }
});

test('unsupported operations fail before invoking a command', async () => {
  for (const action of [['disconnect'], ['setup'], [], ['tap', 42]]) {
    await assert.rejects(run([], [], action), /Supply a session/);
  }
});


test('completed command opens attached image in the same call, including native preparation and rejection', async () => {
  for (const outcome of ['completed', 'unknown', 'not_dispatched']) {
    for (const combined of [false, true]) {
      const observation = {ok: true, phase: 'pre_input_rejection',
        result: {screenshot: '/fixture/screen.png', observation: 'o3', refs: 'current'}};
      const action = {ok: outcome === 'completed', outcome, requiresObservation: true};
      const payload = combined ? {ok: false, action, observation, receipt: '/private/receipt.json'}
        : {...action, observation};
      const execution = {exit_code: payload.ok ? 0 : 1, output: JSON.stringify(payload)};
      const state = memory();
      const output = [], images = [];
      let calls = 0;
      await new AsyncFunction('tools', 'text', 'store', 'image', 'load', start)({
        exec_command: async () => {calls++; return execution;},
        view_image: async ({path}) => {
          assert.equal(path, '/fixture/screen.png');
          assert.deepEqual(output, [{exit_code: execution.exit_code, ...payload}]);
          return {image_url: 'fixture'};
        }
      }, value => output.push(value), state.store, value => images.push(value), state.load);
      assert.equal(calls, 1);
      assert.deepEqual(images, ['fixture']);
      assert.strictEqual(state.load('iphone-use.execution'), execution);
    }
  }
});

test('automatic image reading failure retains completed action for read-only recovery', async () => {
  const payload = {ok: false, outcome: 'unknown', observation: {ok: true, result: {screenshot: '/missing.png'}}};
  const execution = {exit_code: 1, output: JSON.stringify(payload)};
  const state = memory();
  const output = [];
  await assert.rejects(new AsyncFunction('tools', 'text', 'store', 'image', 'load', start)({
    exec_command: async () => execution,
    view_image: async () => {throw new Error('image unavailable');}
  }, value => output.push(value), state.store, () => assert.fail(), state.load), /image unavailable/);
  assert.strictEqual(state.load('iphone-use.execution'), execution);
  assert.deepEqual(output, [{exit_code: 1, ...payload}]);
});
