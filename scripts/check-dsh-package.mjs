// Archive/public-install smoke check. Real Harness runtime acceptance is separate.
import assert from 'node:assert/strict';
import { readFile, realpath } from 'node:fs/promises';
import { join, sep } from 'node:path';
import { pathToFileURL } from 'node:url';

const root = await realpath(process.argv[2]);
const manifest = JSON.parse(await readFile(join(root, 'package.json'), 'utf8'));
assert.equal(manifest.name, 'dsh-iphone-use');
assert.equal(manifest.scripts, undefined);
assert.equal(manifest.dependencies, undefined);
const plugin = await import(pathToFileURL(join(root, manifest.main)).href);
const skills = new Map();
const disposers = [];
await plugin.apply({
  effect: (start) => disposers.push(start()),
  skills: { register(skill) {
    assert.ok(!skills.has(skill.name), 'Duplicate registration');
    skills.set(skill.name, skill);
    return () => skills.delete(skill.name);
  } },
});
assert.equal(skills.size, 1);
const skill = skills.get('iphone-use');
assert.ok(skill.content.includes(`Workflow version: **${manifest.version}**`));
assert.deepEqual(skill.invocation, { modelInvocable: true, userInvocable: true });
for (const path of [skill.path, join(skill.resourceBase.path, 'references/deepseek-harness.md'),
  join(skill.resourceBase.path, 'scripts/preflight.sh'), join(root, manifest.dsh.bundle.patch),
  join(root, manifest.exports['./icon']),
  ...['en', 'zh'].map((locale) => join(root, manifest.exports['./locale/*.json'].replace('*', locale)))]) {
  assert.ok((await realpath(path)).startsWith(root + sep), `Resource escapes package: ${path}`);
  assert.ok((await readFile(path)).length, `Empty resource: ${path}`);
}
for (const dispose of disposers.reverse()) dispose();
assert.equal(skills.size, 0);
console.log(`${manifest.name}@${manifest.version}: installed package registration, resources and disposal passed (test registry)`);
