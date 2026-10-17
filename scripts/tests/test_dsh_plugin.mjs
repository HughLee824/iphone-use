import assert from 'node:assert/strict';
import { cp, mkdtemp, readFile, realpath, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import test from 'node:test';

const pluginRoot = fileURLToPath(new URL('../../plugins/iphone-use/', import.meta.url));

async function relocatedPlugin(t) {
  const temporary = await realpath(await mkdtemp(join(tmpdir(), 'iphone-use-dsh-')));
  t.after(() => rm(temporary, { recursive: true, force: true }));
  const root = join(temporary, 'plugin with spaces');
  await cp(pluginRoot, root, { recursive: true });
  const plugin = await import(pathToFileURL(join(root, 'deepseek.js')).href);
  return { root, plugin };
}

test('relocated plugin loads the canonical skill and unregisters on disposal', async (t) => {
  const { root, plugin } = await relocatedPlugin(t);
  const registrations = new Map();
  const disposers = [];
  const ctx = {
    effect: (start) => disposers.push(start()),
    skills: {
      register(skill) {
        registrations.set(skill.name, skill);
        return () => registrations.delete(skill.name);
      },
    },
  };
  assert.deepEqual(plugin.inject, ['skills']);
  await plugin.apply(ctx);
  assert.equal(registrations.size, 1);
  const skill = registrations.get('iphone-use');
  const canonical = await readFile(new URL('../../skills/iphone-use/SKILL.md', import.meta.url), 'utf8');
  assert.equal(skill.description, canonical.match(/^description: (.+)$/m)[1]);
  assert.equal(skill.content, canonical.replace(/^---\r?\n[\s\S]*?\r?\n---\r?\n/, ''));
  assert.deepEqual(skill.invocation, { modelInvocable: true, userInvocable: true });
  assert.equal(skill.path, join(root, 'skills/iphone-use/SKILL.md'));
  assert.equal(skill.resourceBase.kind, 'directory');
  assert.equal(await readFile(join(skill.resourceBase.path, 'scripts/preflight.sh'), 'utf8'),
    await readFile(new URL('../../skills/iphone-use/scripts/preflight.sh', import.meta.url), 'utf8'));
  const adapter = await readFile(join(skill.resourceBase.path, 'references/deepseek-harness.md'), 'utf8');
  assert.ok(adapter.length > 0);
  for (const dispose of disposers.reverse()) dispose();
  assert.equal(registrations.size, 0);
});

test('invalid or missing packaged skill fails before registration', async (t) => {
  const { root, plugin } = await relocatedPlugin(t);
  const ctx = { effect: () => assert.fail('must not register invalid skill') };
  const path = join(root, 'skills/iphone-use/SKILL.md');
  await writeFile(path, '---\nname: wrong-skill\ndescription: Wrong\n---\nBody');
  await assert.rejects(plugin.apply(ctx), /Invalid bundled/);
  await rm(path);
  await assert.rejects(plugin.apply(ctx), { code: 'ENOENT' });
});

test('npm pack includes every exported resource and no installation scripts', async (t) => {
  const { root } = await relocatedPlugin(t);
  const { execFileSync } = await import('node:child_process');
  const manifest = JSON.parse(await readFile(join(root, 'package.json'), 'utf8'));
  assert.equal(manifest.scripts, undefined);
  assert.equal(manifest.dependencies, undefined);
  const [packed] = JSON.parse(execFileSync('npm', ['pack', '--dry-run', '--json', '--ignore-scripts',
    '--cache', join(root, '.npm-cache')], { cwd: root, encoding: 'utf8' }));
  const files = new Set(packed.files.map((file) => file.path));
  for (const path of [manifest.main, manifest.dsh.bundle.patch, manifest.exports['./icon'],
    'locale/en.json', 'locale/zh.json', 'LICENSE', 'skills/iphone-use/SKILL.md',
    'skills/iphone-use/references/deepseek-harness.md', 'skills/iphone-use/scripts/preflight.sh']) {
    assert.ok(files.has(path.replace(/^\.\//, '')), `Missing npm package file: ${path}`);
  }
  assert.ok([...files].every((path) => !path.includes('node_modules') && !path.includes('.npm-cache')));
});

test('repository package can be packed and loaded without the source checkout', async (t) => {
  const { execFileSync } = await import('node:child_process');
  const temporary = await realpath(await mkdtemp(join(tmpdir(), 'iphone-use-root-package-')));
  t.after(() => rm(temporary, { recursive: true, force: true }));
  const root = fileURLToPath(new URL('../../', import.meta.url));
  const [packed] = JSON.parse(execFileSync('npm', ['pack', '--json', '--ignore-scripts',
    '--cache', join(temporary, 'cache'), '--pack-destination', temporary], { cwd: root, encoding: 'utf8' }));
  assert.ok(packed.files.every(({ path }) => path.startsWith('plugins/iphone-use/')
    || ['package.json', 'README.md', 'README.zh-CN.md', 'LICENSE'].includes(path)), 'Only public plugin files may ship');
  execFileSync('tar', ['-xzf', join(temporary, packed.filename), '-C', temporary]);
  const installed = join(temporary, 'package');
  const manifest = JSON.parse(await readFile(join(installed, 'package.json'), 'utf8'));
  assert.equal(manifest.name, 'dsh-iphone-use');
  for (const path of [manifest.dsh.bundle.patch, manifest.exports['./icon'],
    manifest.exports['./locale/*.json'].replace('*', 'en'),
    manifest.exports['./locale/*.json'].replace('*', 'zh')]) {
    assert.ok((await readFile(join(installed, path))).length);
  }
  const plugin = await import(pathToFileURL(join(installed, manifest.main)).href);
  let skill;
  await plugin.apply({ effect: (start) => start(), skills: { register: (value) => { skill = value; } } });
  assert.equal(skill.name, 'iphone-use');
  assert.ok(skill.resourceBase.path.startsWith(installed + '/'));
  assert.ok((await readFile(join(skill.resourceBase.path, 'references/deepseek-harness.md'))).length);
});

// Optional integration check against an installed Harness, without a model,
// user profile, device connection, or an additional copy of its dependencies.
test('actual Harness registry loads and disposes the relocated plugin', {
  skip: !process.env.DSH_RUNTIME_MODULES,
}, async (t) => {
  const { plugin } = await relocatedPlugin(t);
  const runtime = process.env.DSH_RUNTIME_MODULES;
  const { Context } = await import(pathToFileURL(join(runtime, '@deepseek-ai/cordis/lib/index.js')).href);
  const { SkillRegistry } = await import(pathToFileURL(join(runtime, '@deepseek-ai/dsh-skill/lib/index.js')).href);
  const ctx = new Context();
  const registry = ctx.plugin(SkillRegistry);
  const fork = ctx.plugin(plugin);
  t.after(async () => {
    await fork.dispose();
    await registry.dispose();
  });
  let skill;
  for (let attempt = 0; attempt < 100; attempt++) {
    skill = await ctx.skills?.get('iphone-use');
    if (skill) break;
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
  assert.ok(skill, 'Harness must load the skill within one second');
  assert.equal((await ctx.skills.list()).filter((entry) => entry.name === 'iphone-use').length, 1);
  assert.deepEqual(skill.invocation, { modelInvocable: true, userInvocable: true });
  assert.equal(await readFile(skill.path, 'utf8'),
    await readFile(join(skill.resourceBase.path, 'SKILL.md'), 'utf8'));
  assert.ok((await readFile(join(skill.resourceBase.path, 'references/deepseek-harness.md'), 'utf8')).length);
  await fork.dispose();
  assert.equal(await ctx.skills.get('iphone-use'), undefined);
});
