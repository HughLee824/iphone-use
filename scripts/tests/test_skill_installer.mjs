import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { cp, mkdir, mkdtemp, readFile, realpath, rm, symlink, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import test from 'node:test';
import { run } from '../../packages/iphone-use-skill/bin/iphone-use-skill.mjs';
const repository = fileURLToPath(new URL('../../', import.meta.url));

async function fixture(t) {
  const root = await realpath(await mkdtemp(join(tmpdir(), 'iu-skill-test-')));
  t.after(() => rm(root, { recursive: true, force: true }));
  const home = join(root, 'home');
  const project = join(root, 'project with spaces');
  const source = join(root, 'source');
  await mkdir(home); await mkdir(project); await mkdir(join(project, '.git'));
  await cp(join(repository, 'skills/iphone-use'), source, { recursive: true });
  const options = { agent: 'cursor', project, home, source };
  return { root, home, project, source, options, call: (command, overrides = {}) => run({ ...options, command, ...overrides }) };
}
async function skill(path, name = 'iphone-use') {
  await mkdir(path, { recursive: true });
  await writeFile(join(path, 'SKILL.md'), `---\nname: ${name}\ndescription: Test\n---\nBody`);
}

test('install, exact repeat and uninstall keep other clients and files untouched', async (t) => {
  const f = await fixture(t);
  await skill(join(f.home, '.codex/plugins/cache/iphone-use/iphone-use/0.1.11/skills/iphone-use'));
  await skill(join(f.home, '.claude/plugins/cache/iphone-use/iphone-use/0.1.11/skills/iphone-use'));
  await skill(join(f.home, '.deepseek-harness/profiles/desktop/node_modules/dsh-iphone-use/skills/iphone-use'));
  const first = await f.call('install');
  assert.equal(first.target, join(f.project, '.cursor/skills/iphone-use'));
  assert.equal(first.result, 'installed');
  assert.equal((await f.call('install')).result, 'already-installed');
  assert.equal((await f.call('check')).state, 'managed');
  await assert.rejects(readFile(join(f.project, '.agents/skills/iphone-use/SKILL.md')), { code: 'ENOENT' });
  assert.equal((await f.call('uninstall')).result, 'uninstalled');
  assert.equal((await f.call('uninstall')).result, 'already-absent');
  assert.ok(await readFile(join(f.home, '.codex/plugins/cache/iphone-use/iphone-use/0.1.11/skills/iphone-use/SKILL.md')));
});

test('global, ancestor, nested, quoted-name and compatibility-root duplicates block installation', async (t) => {
  for (const where of ['global', 'ancestor', 'nested', 'compatibility', 'quoted']) {
    const f = await fixture(t);
    const child = join(f.project, 'apps/web'); await mkdir(child, { recursive: true });
    const paths = {
      global: join(f.home, '.agents/skills/iphone-use'),
      ancestor: join(f.project, '.claude/skills/category/iphone-use'),
      nested: join(child, '.cursor/skills/category/iphone-use'),
      compatibility: join(f.home, '.codex/skills/iphone-use'),
      quoted: join(f.home, '.cursor/skills/category/alias'),
    };
    await skill(paths[where]);
    if (where === 'quoted') await writeFile(join(paths[where], 'SKILL.md'), '---\nname: "iphone-use"\ndescription: test\n---\n');
    const project = where === 'ancestor' ? child : f.project;
    const report = await f.call('check', { project });
    assert.equal(report.conflicts.length, 1, where);
    await assert.rejects(f.call('install', { project }), /Conflicting skills/, where);
    await assert.rejects(readFile(join(project, '.cursor/skills/iphone-use/SKILL.md')), { code: 'ENOENT' });
    assert.ok(await readFile(join(paths[where], 'SKILL.md')));
  }
});

test('unmanaged content and modified/extra managed files are preserved', async (t) => {
  const f = await fixture(t);
  const target = join(f.project, '.cursor/skills/iphone-use');
  await skill(target);
  for (const command of ['install', 'update', 'uninstall']) await assert.rejects(f.call(command), /unmanaged/);
  await rm(target, { recursive: true });
  await f.call('install');
  await writeFile(join(target, 'my-notes.txt'), 'preserve me');
  assert.equal((await f.call('check')).state, 'modified');
  for (const command of ['install', 'update', 'uninstall']) await assert.rejects(f.call(command), /modified/);
  assert.equal(await readFile(join(target, 'my-notes.txt'), 'utf8'), 'preserve me');
});

test('explicit update replaces only unmodified managed content', async (t) => {
  const f = await fixture(t); await f.call('install');
  await writeFile(join(f.source, 'references/generic-agent.md'), 'Updated adapter');
  await assert.rejects(f.call('install'), /use update/);
  assert.equal((await f.call('update')).result, 'updated');
  assert.equal((await f.call('check')).state, 'managed');
  assert.equal(await readFile(join(f.project, '.cursor/skills/iphone-use/references/generic-agent.md'), 'utf8'), 'Updated adapter');
});

test('links cannot redirect writes into shared directories; aliases count as duplicates', async (t) => {
  const f = await fixture(t);
  await mkdir(join(f.project, '.cursor'));
  const shared = join(f.home, '.agents/skills'); await mkdir(shared, { recursive: true });
  await symlink(shared, join(f.project, '.cursor/skills'));
  await assert.rejects(f.call('install'), /linked destination/);
  await rm(join(f.project, '.cursor/skills'));
  await f.call('install');
  await symlink(join(f.project, '.cursor/skills/iphone-use'), join(shared, 'iphone-use'));
  assert.equal((await f.call('check')).conflicts.length, 1);
  await assert.rejects(f.call('update'), /Conflicting skills/);
  await f.call('uninstall'); // Removing our own source is allowed; no alias is deleted.
  await assert.rejects(realpath(join(shared, 'iphone-use')), { code: 'ENOENT' });
});

test('installed plugin clients are not given a second standalone copy', async (t) => {
  const f = await fixture(t);
  for (const agent of ['codex', 'claude-code', 'deepseek-harness']) {
    await assert.rejects(f.call('install', { agent }), /existing iPhone-use plugin/);
  }
});

test('global private paths and OpenCode compatibility conflicts', async (t) => {
  const f = await fixture(t);
  assert.equal((await f.call('install', { global: true })).target, join(f.home, '.cursor/skills/iphone-use'));
  await f.call('uninstall', { global: true });
  const installed = await f.call('install', { agent: 'opencode' });
  assert.equal(installed.target, join(f.project, '.opencode/skills/iphone-use'));
  await skill(join(f.home, '.claude/skills/iphone-use'));
  await assert.rejects(f.call('update', { agent: 'opencode' }), /Conflicting skills/);
});

test('an existing lock prevents a second mutation', async (t) => {
  const f = await fixture(t); await f.call('install');
  await writeFile(join(f.project, '.cursor/skills/.iphone-use-install.lock'), 'other operation');
  await assert.rejects(f.call('uninstall'), { code: 'EEXIST' });
  assert.equal((await f.call('check')).state, 'managed');
});

test('OpenCode can create a new XDG config root but refuses a linked root', async (t) => {
  const f = await fixture(t);
  const previous = process.env.XDG_CONFIG_HOME;
  try {
    const config = join(f.root, 'new-config');
    process.env.XDG_CONFIG_HOME = config;
    const result = await f.call('install', { agent: 'opencode', global: true });
    assert.equal(result.target, join(config, 'opencode/skills/iphone-use'));
    assert.equal((await f.call('check', { agent: 'opencode', global: true })).state, 'managed');
    await f.call('uninstall', { agent: 'opencode', global: true });
    const alias = join(f.root, 'linked-config');
    await symlink(config, alias);
    process.env.XDG_CONFIG_HOME = alias;
    await assert.rejects(f.call('install', { agent: 'opencode', global: true }), /linked destination/);
  } finally {
    if (previous === undefined) delete process.env.XDG_CONFIG_HOME;
    else process.env.XDG_CONFIG_HOME = previous;
  }
});

test('packed installer works through npm exec outside the checkout', async (t) => {
  const f = await fixture(t);
  const staging = join(f.root, 'package');
  execFileSync('python3', [join(repository, 'scripts/plugin/build-skill-package.py'), staging]);
  const [pack] = JSON.parse(execFileSync('npm', ['pack', '--json', '--ignore-scripts', '--cache', join(f.root, 'cache'), '--pack-destination', f.root], { cwd: staging, encoding: 'utf8' }));
  assert.ok(pack.files.every(({ path }) => path.startsWith('bin/') || path.startsWith('skills/') || ['package.json', 'README.md', 'LICENSE'].includes(path)));
  assert.ok(pack.files.some(({ path }) => path === 'skills/iphone-use/references/generic-agent.md'));
  const manifest = JSON.parse(await readFile(join(staging, 'package.json')));
  assert.equal(manifest.dependencies, undefined); assert.equal(manifest.scripts, undefined);
  const result = JSON.parse(execFileSync('npm', ['exec', '--yes', '--offline', '--ignore-scripts', '--cache', join(f.root, 'cache'), `--package=${join(f.root, pack.filename)}`, '--', 'iphone-use-skill', 'install', '--agent', 'cursor', '--project', f.project], { cwd: f.root, encoding: 'utf8' }));
  assert.equal(result.result, 'installed');
  const installed = await readFile(join(result.target, 'SKILL.md'), 'utf8');
  assert.equal(installed, await readFile(join(repository, 'skills/iphone-use/SKILL.md'), 'utf8'));
});

test('update refuses downgrade and permission errors do not become clean scans', async (t) => {
  const f = await fixture(t); await f.call('install');
  const path = join(f.source, 'SKILL.md');
  await writeFile(path, (await readFile(path, 'utf8')).replace(/Workflow version: \*\*[\d.]+\*\*/, 'Workflow version: **0.0.0**'));
  await assert.rejects(f.call('update'), /Refusing downgrade/);
  // A dangling link in a discovery root is unresolved, not proof of no conflict.
  await mkdir(join(f.home, '.agents/skills'), { recursive: true });
  await symlink(join(f.home, 'missing'), join(f.home, '.agents/skills/unresolved'));
  await assert.rejects(f.call('check'), { code: 'ENOENT' });
});

test('an alias later in the same discovery root is not hidden by cycle detection', async (t) => {
  const f = await fixture(t); await f.call('install');
  const root = join(f.project, '.cursor/skills');
  await symlink(join(root, 'iphone-use'), join(root, 'zz-alias'));
  const result = await f.call('check');
  assert.ok(result.conflicts.some(({ path }) => path.endsWith('zz-alias')));
  await assert.rejects(f.call('install'), /Conflicting skills/);
});
