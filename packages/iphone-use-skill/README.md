# iPhone-use portable skill

Install the shared iPhone-use skill into Cursor or OpenCode with Node.js 20+:

```sh
npx iphone-use-skill install --agent cursor
npx iphone-use-skill check --agent cursor
# Or use --agent opencode. Add --global for a user-level installation.
npx iphone-use-skill update --agent cursor
npx iphone-use-skill uninstall --agent cursor
```

The default target is `.cursor/skills/iphone-use` or `.opencode/skills/iphone-use` in the current project. Use `--project /absolute/project/path` to select a project. Global targets are `~/.cursor/skills/iphone-use` and `$XDG_CONFIG_HOME/opencode/skills/iphone-use` (default `~/.config`). Run checks from the project you will use, even for a global installation.

This package contains instructions and an installer, not the iPhone-use CLI. Install that separately with `brew install HughLee824/tap/iphone-use`. The agent's shell and image reader must run on the Mac connected to the phone. A remote/cloud agent or a multimodal model without local PNG reading does not meet that requirement.

## Duplicate handling

- Identical managed installs are a no-op. Different payloads require explicit `update`.
- Existing unmanaged directories, local edits/additions, links at the target, and linked destination parents are never overwritten or removed.
- Installation/update checks same-name `iphone-use` and legacy `agentsoma` skills in the selected client's known local/global compatibility roots, ancestor roots up to the Git worktree root, and nested project roots. Nested skill category folders and symlink aliases are inspected. Conflicts block mutation and print their paths; there is no `--force` bypass.
- Codex, Claude Code and DeepSeek Harness remain plugin-managed installation targets. Requests to add a standalone copy for these clients are rejected. Their plugin caches are not Cursor/OpenCode skill discovery roots and are not changed by this installer.
- `check` prints JSON and exits 2 for conflicts or unmanaged/modified targets. Operational failures exit 1. A clean check (including no installation) exits 0.
- Update/uninstall only touch this installer's unmodified, recorded files. A sibling lock serializes installer operations; if interrupted, inspect the destination and any `.iphone-use-stage-*` recovery directory before removing a stale `.iphone-use-install.lock`.

These checks cover known filesystem discovery roots, not every agent configuration. Remote/team/organization skills, additional configured directories, explicitly loaded plugins, and skills added later can still introduce duplicates. Inspect the client's advertised skills when starting a new session and run `check` after changing its configuration. Keep one enabled iPhone-use source in each client. A clean filesystem check is not proof of runtime uniqueness or phone readiness.

A generic `npx skills add ...` installer does not run this package's conflict checks. Do not substitute it when you need the managed installation behavior above. This installer writes no shared `.agents/skills` copy and does not create symlinks or modify plugin settings.

## Development and verification

The canonical skill lives at `skills/iphone-use` in the repository. Build a fresh staging directory before packing; the source package directory intentionally has no duplicated skill tree:

```sh
python3 scripts/build-skill-package.py /tmp/iphone-use-skill-package
cd /tmp/iphone-use-skill-package
npm pack --ignore-scripts
```

The generated package contains the full skill, references, scripts, icons and license. Use a temporary project to test the packed package with `npm exec --package=/absolute/package.tgz -- iphone-use-skill install --agent cursor --project /absolute/project` before publication. Directly running or packing the source package without staging is not a release workflow.
