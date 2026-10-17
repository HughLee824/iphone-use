#!/usr/bin/env node
import { createHash } from 'node:crypto';
import { cp, lstat, mkdir, mkdtemp, open, readFile, readdir, realpath, rename, rm, writeFile } from 'node:fs/promises';
import { homedir } from 'node:os';
import { basename, dirname, join, parse, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const markerName = '.iphone-use-install.json';
const owner = 'iphone-use-skill';
const names = new Set(['iphone-use', 'agentsoma']);
const targets = {
  cursor: { project: '.cursor/skills', global: '.cursor/skills', roots: ['.cursor/skills', '.agents/skills', '.claude/skills', '.codex/skills'] },
  opencode: { project: '.opencode/skills', global: '.config/opencode/skills', roots: ['.opencode/skills', '.agents/skills', '.claude/skills'] },
};
const ignored = new Set(['.git', 'node_modules', '.build', '.venv', 'venv', 'vendor', '.next', 'dist']);

async function stat(path) {
  try { return await lstat(path); } catch (error) {
    if (error.code === 'ENOENT') return undefined;
    throw error; // An unreadable location is not an empty location.
  }
}
const digest = (bytes) => createHash('sha256').update(bytes).digest('hex');

async function fingerprint(root) {
  const files = {};
  async function visit(directory, relative = '') {
    for (const entry of (await readdir(directory)).sort()) {
      if (!relative && entry === markerName) continue;
      const path = join(directory, entry);
      const info = await lstat(path);
      if (info.isSymbolicLink()) throw new Error(`Symlink inside skill: ${path}`);
      const name = relative ? `${relative}/${entry}` : entry;
      if (info.isDirectory()) await visit(path, name);
      else if (info.isFile()) files[name] = digest(await readFile(path));
      else throw new Error(`Unsupported file: ${path}`);
    }
  }
  await visit(root);
  return files;
}
const equal = (a, b) => JSON.stringify(a) === JSON.stringify(b);

async function managedState(target, agent) {
  if (!await stat(target)) return { state: 'absent' };
  if ((await lstat(target)).isSymbolicLink()) return { state: 'unmanaged', reason: 'destination is a symlink' };
  let marker;
  try { marker = JSON.parse(await readFile(join(target, markerName), 'utf8')); }
  catch (error) {
    if (error.code === 'ENOENT' || error instanceof SyntaxError) return { state: 'unmanaged' };
    throw error;
  }
  if (marker.owner !== owner || marker.agent !== agent || marker.schema !== 1) return { state: 'unmanaged' };
  const files = await fingerprint(target);
  if (!equal(files, marker.files)) return { state: 'modified', version: marker.version };
  return { state: 'managed', version: marker.version, files };
}

// Only inspect skill discovery roots; plugin caches for OTHER clients are not
// discovered by Cursor/OpenCode and must not prevent their independent installs.
async function conflicts({ agent, project, home, target }) {
  const config = targets[agent];
  const roots = new Set(config.roots.map((root) => join(home, root)));
  roots.add(join(home, config.global));
  if (agent === 'opencode' && process.env.XDG_CONFIG_HOME) roots.add(join(process.env.XDG_CONFIG_HOME, 'opencode/skills'));
  let ancestor = project;
  while (true) {
    for (const root of config.roots) roots.add(join(ancestor, root));
    if (await stat(join(ancestor, '.git')) || dirname(ancestor) === ancestor) break;
    ancestor = dirname(ancestor);
  }
  // Nested project skills can become visible after changing the active file.
  // Bound traversal and report an incomplete scan instead of declaring it safe.
  let visitedCount = 0;
  async function nested(directory) {
    if (++visitedCount > 20000) throw new Error('Project scan exceeds 20000 directories; choose a narrower --project.');
    for (const entry of await readdir(directory, { withFileTypes: true })) {
      if (!entry.isDirectory() || ignored.has(entry.name)) continue;
      const path = join(directory, entry.name);
      if (['.cursor', '.agents', '.claude', '.codex', '.opencode'].includes(entry.name)) {
        for (const root of config.roots) if (root.startsWith(entry.name + '/')) roots.add(join(directory, root));
      } else await nested(path);
    }
  }
  await nested(project);
  const seen = new Set();
  const found = [];
  async function inspect(path, depth = 0) {
    if (!await stat(path)) return;
    const canonical = await realpath(path);
    if (depth > 24 || seen.size > 20000) throw new Error(`Skill scan limit reached at ${path}`);
    if (!(await lstat(canonical)).isDirectory()) return;
    const document = join(canonical, 'SKILL.md');
    if (await stat(document)) {
      const content = await readFile(document, 'utf8');
      const identity = content.match(/^---\r?\n[\s\S]*?^name:\s*["']?([a-z0-9-]+)["']?\s*$/m)?.[1];
      if (names.has(identity) || names.has(basename(path))) {
        // A second alias of the destination is still a conflict: clients may
        // list both even though their physical contents are identical.
        if (resolve(path) !== target) found.push({ path, name: identity ?? basename(path) });
      }
    }
    if (seen.has(canonical)) return;
    seen.add(canonical);
    for (const entry of await readdir(canonical, { withFileTypes: true })) {
      if (entry.isDirectory() || entry.isSymbolicLink()) await inspect(join(path, entry.name), depth + 1);
    }
  }
  // Inspect aliases separately, while still bounding cycles in each root.
  for (const root of [...roots].sort()) { seen.clear(); await inspect(root); }
  return [...new Map(found.map((item) => [item.path, item])).values()];
}

async function noSymlinkParents(base, directory) {
  let current = directory;
  while (current !== base) {
    const info = await stat(current);
    if (info?.isSymbolicLink()) throw new Error(`Refusing linked destination directory: ${current}`);
    if (dirname(current) === current) throw new Error('Destination is outside installation scope');
    current = dirname(current);
  }
}

export async function run({ command, agent, project = process.cwd(), global = false, home = homedir(), source }) {
  if (!targets[agent]) {
    if (['codex', 'claude-code', 'deepseek-harness'].includes(agent)) {
      throw new Error(`${agent}: use the existing iPhone-use plugin; this installer will not add a duplicate standalone skill.`);
    }
    throw new Error('Select --agent cursor or --agent opencode. No automatic all-agent installation.');
  }
  if (!['install', 'check', 'update', 'uninstall'].includes(command)) throw new Error('Expected install, check, update or uninstall');
  project = await realpath(resolve(project));
  home = await realpath(resolve(home));
  const base = global ? home : project;
  const relative = global ? targets[agent].global : targets[agent].project;
  const directory = global && agent === 'opencode' && process.env.XDG_CONFIG_HOME
    ? resolve(process.env.XDG_CONFIG_HOME, 'opencode/skills') : join(base, relative);
  const target = join(directory, 'iphone-use');
  // A new external XDG root need not exist yet. Check every existing ancestor
  // so linked roots cannot redirect installation outside the selected path.
  const scope = global && agent === 'opencode' && process.env.XDG_CONFIG_HOME
    ? parse(directory).root : base;
  await noSymlinkParents(scope, directory);
  const inspect = async () => ({
    agent, target, ...await managedState(target, agent),
    conflicts: await conflicts({ agent, project, home, target }),
  });
  if (command === 'check') return inspect();
  let report = await inspect();
  if (command !== 'uninstall' && report.conflicts.length) throw new Error(`Conflicting skills:\n${report.conflicts.map((c) => c.path).join('\n')}\nKeep one enabled source in this client; no files changed.`);
  if (['unmanaged', 'modified'].includes(report.state)) throw new Error(`Refusing to ${command} ${report.state} directory: ${target}. Preserve/migrate it explicitly; no files changed.`);
  if (command === 'uninstall' && report.state === 'absent') return { ...report, result: 'already-absent' };
  const files = command === 'uninstall' ? undefined : await fingerprint(source);
  const body = command === 'uninstall' ? '' : await readFile(join(source, 'SKILL.md'), 'utf8');
  const version = body.match(/Workflow version: \*\*([\w.+-]+)\*\*/)?.[1];
  if (command !== 'uninstall' && (!version || !body.startsWith('---\nname: iphone-use\n'))) throw new Error('Invalid packaged skill');
  if (command === 'install' && report.state === 'managed') {
    if (equal(files, report.files)) return { ...report, result: 'already-installed' };
    throw new Error(`Installed version ${report.version} differs; use update explicitly.`);
  }
  if (command === 'update' && report.state === 'absent') throw new Error('No managed installation; use install first.');
  if (command === 'update') {
    const parts = (value) => /^\d+\.\d+\.\d+$/.test(value) ? value.split('.').map(Number) : undefined;
    const oldVersion = parts(report.version);
    const newVersion = parts(version);
    if (!oldVersion || !newVersion) throw new Error('Cannot safely compare skill versions.');
    const difference = newVersion.map((value, index) => value - oldVersion[index]).find((value) => value !== 0);
    if (difference < 0) throw new Error(`Refusing downgrade from ${report.version} to ${version}.`);
  }
  await mkdir(directory, { recursive: true });
  const lockPath = join(directory, '.iphone-use-install.lock');
  const lock = await open(lockPath, 'wx');
  let staging;
  let preserveRecovery = false;
  try {
    // Refuse racing changes; every writer through this installer shares a lock.
    const current = await inspect();
    if (!equal(current, report)) throw new Error('Installation changed during inspection; rerun check.');
    staging = await mkdtemp(join(dirname(directory), '.iphone-use-stage-'));
    const backup = join(staging, 'previous');
    if (command !== 'uninstall') {
      await cp(source, join(staging, 'next'), { recursive: true, errorOnExist: true });
      if (!equal(await fingerprint(join(staging, 'next')), files)) throw new Error('Package changed while staging.');
      await writeFile(join(staging, 'next', markerName), JSON.stringify({ schema: 1, owner, agent, version, files }, null, 2) + '\n');
    }
    if (!equal(await inspect(), report)) throw new Error('Installation changed while staging; rerun check.');
    if (report.state === 'managed') await rename(target, backup);
    try {
      if (command !== 'uninstall') await rename(join(staging, 'next'), target);
    } catch (error) {
      if (report.state === 'managed') {
        try { await rename(backup, target); }
        catch {
          preserveRecovery = true;
          throw new Error(`Update failed; previous files preserved at ${backup}. Restore them before retrying.`, { cause: error });
        }
      }
      throw error;
    }
    return { agent, target, version, result: command === 'uninstall' ? 'uninstalled' : command === 'update' ? 'updated' : 'installed' };
  } finally {
    if (staging && !preserveRecovery) await rm(staging, { recursive: true, force: true });
    await lock.close();
    await rm(lockPath);
  }
}

async function main() {
  const args = process.argv.slice(2);
  if (!args.length || args.includes('--help')) {
    console.log('Usage: iphone-use-skill <install|check|update|uninstall> --agent <cursor|opencode> [--project PATH] [--global]\nDefault: project-private skill directory. No shared-directory writes or plugin replacement.\ncheck exits 2 for conflicts, modified or unmanaged installations.');
    return;
  }
  const options = { command: args.shift(), source: fileURLToPath(new URL('../skills/iphone-use/', import.meta.url)) };
  while (args.length) {
    const flag = args.shift();
    if (flag === '--global') options.global = true;
    else if (['--agent', '--project'].includes(flag) && args[0] && !args[0].startsWith('--')) options[flag.slice(2)] = args.shift();
    else throw new Error(`Unknown or incomplete option: ${flag}`);
  }
  const result = await run(options);
  console.log(JSON.stringify(result, null, 2));
  if (result.conflicts?.length || ['unmanaged', 'modified'].includes(result.state)) process.exitCode = 2;
}
if (process.argv[1] && pathToFileURL(await realpath(resolve(process.argv[1]))).href === import.meta.url) {
  main().catch((error) => { console.error(error.message); process.exitCode = 1; });
}
