import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';

export const name = 'iphone-use-skill';
export const inject = ['skills'];

export async function apply(ctx) {
  const directory = new URL('./skills/iphone-use/', import.meta.url);
  const path = fileURLToPath(new URL('SKILL.md', directory));
  const document = await readFile(path, 'utf8');
  // The canonical skill uses these two plain YAML scalars. Fail on format drift
  // instead of registering an incomplete or incorrectly named skill.
  const frontmatter = document.match(/^---\r?\nname: ([a-z0-9-]+)\r?\ndescription: ([^\r\n]+)\r?\n---\r?\n/);
  if (!frontmatter || frontmatter[1] !== 'iphone-use') {
    throw new Error('Invalid bundled iPhone-use skill frontmatter');
  }
  ctx.effect(() => ctx.skills.register({
    name: frontmatter[1],
    description: frontmatter[2],
    path,
    source: 'runtime',
    resourceBase: { kind: 'directory', path: fileURLToPath(directory) },
    invocation: { modelInvocable: true, userInvocable: true },
    content: document.slice(frontmatter[0].length),
  }));
}
