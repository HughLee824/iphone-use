// Run with the installed Harness runtime, not a separate copy of Cordis.
import assert from 'node:assert/strict';
import { readFile, realpath } from 'node:fs/promises';
import { join, sep } from 'node:path';
import { pathToFileURL } from 'node:url';

const runtime = process.env.DSH_RUNTIME_MODULES;
assert.ok(runtime && process.argv[2], 'Set DSH_RUNTIME_MODULES and pass the installed dsh-iphone-use package directory');
const root = await realpath(process.argv[2]);
const manifest = JSON.parse(await readFile(join(root, 'package.json'), 'utf8'));
assert.equal(manifest.name, 'dsh-iphone-use');
const { Context } = await import(pathToFileURL(join(runtime, '@deepseek-ai/cordis/lib/index.js')).href);
const { SkillRegistry } = await import(pathToFileURL(join(runtime, '@deepseek-ai/dsh-skill/lib/index.js')).href);
const plugin = await import(pathToFileURL(join(root, manifest.main)).href);
const ctx = new Context();
const registry = ctx.plugin(SkillRegistry);
const fork = ctx.plugin(plugin);
try {
  let skill;
  for (let attempt = 0; attempt < 100; attempt++) {
    skill = await ctx.skills?.get('iphone-use');
    if (skill) break;
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
  assert.ok(skill, 'Skill registration did not complete');
  assert.equal((await ctx.skills.list()).filter((entry) => entry.name === 'iphone-use').length, 1);
  assert.deepEqual(skill.invocation, { modelInvocable: true, userInvocable: true });
  assert.ok(skill.content.includes(`Workflow version: **${manifest.version}**`));
  for (const path of [skill.path, join(skill.resourceBase.path, 'references/deepseek-harness.md'),
    join(skill.resourceBase.path, 'scripts/preflight.sh'), join(root, manifest.dsh.bundle.patch),
    join(root, manifest.exports['./icon']),
    join(root, manifest.exports['./locale/*.json'].replace('*', 'en')),
    join(root, manifest.exports['./locale/*.json'].replace('*', 'zh'))]) {
    assert.ok((await realpath(path)).startsWith(root + sep), `Resource escapes installed package: ${path}`);
    assert.ok((await readFile(path)).length, `Empty resource: ${path}`);
  }
  await fork.dispose();
  assert.equal(await ctx.skills.get('iphone-use'), undefined);
  console.log(JSON.stringify({ package: manifest.name, version: manifest.version,
    installedAt: root, skill: skill.name, resourceBase: skill.resourceBase,
    registration: 'passed', resources: 'passed', disposal: 'passed' }, null, 2));
} finally {
  await fork.dispose();
  await registry.dispose();
}
