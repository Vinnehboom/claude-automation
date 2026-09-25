# claude-automation

This repository is a Claude Code plugin marketplace. It holds one plugin,
`kanban-automation`. The plugin runs a project's Notion kanban board
against that project's GitHub pull requests.

The logic lives here. The pointers to each board and repository live in
the project that uses the plugin.

## Skills in the plugin

| Skill | Function |
| --- | --- |
| `kanban-cycle` | Runs one scheduled review cycle. It triages open pull requests first, then starts at most one new ticket. |
| `ticket-pipeline` | Drives one ticket from its Notion card to a reviewed pull request. |
| `handoff` | Retires the standing orchestrator session and gives the role to a new session. |
| `coding-style` | Records a durable style preference into the style guide page of the project. |

The plugin also ships `scripts/ui_capture/`, the screenshot driver the
`ticket-pipeline` Gatekeeper runs. Address it as
`${CLAUDE_PLUGIN_ROOT}/scripts/ui_capture/run.sh` — the install path carries
the plugin version, so never write it out by hand.

## What each project supplies

The plugin reads these files from the project repository. Create them
before you enable the plugin:

- `.claude/kanban-cycle.json` — the repository, the board URL, and the caps.
- `.claude/knowledge-base.json` — the knowledge base, decisions, and tech debt pages.
- `.claude/coding-style.json` — the style guide page.
- `.claude/ui-capture.json` — how to boot the app, how to list its own
  page-rendering routes, and how to sign in. Only the Gatekeeper's UI
  capture reads this one. A project without it skips the capture with a
  clear message. See `plugins/kanban-automation/scripts/ui_capture/README.md`.

Each project also keeps its own session-start hook. That hook installs the
test environment of one project, so it cannot move into this plugin. The
boot script that `.claude/ui-capture.json` names is the same case.

### The `simple-english` skill stays with each project

The `ticket-pipeline` briefs tell the planner, the developer, and the
curator to write their prose with a `simple-english` skill. This plugin
does not supply that skill, and it does not ship a copy of ASD-STE100.
Keep your own copy in the project's `.claude/skills/`, under whatever
terms you hold it under.

If a project has no such skill, those instructions find nothing and the
phase writes ordinary prose. Nothing else breaks.

## Install the plugin in a project

The install is what puts the plugin on disk. A declaration in
`.claude/settings.json` does not. Measured 2026-09-06: a project settings
file that carries `extraKnownMarketplaces` and `enabledPlugins` installs
nothing, and `claude plugin list` answers "No plugins installed". A
successful install writes those two keys itself. They are a receipt, not
a request.

### In a terminal

```sh
claude plugin marketplace add Vinnehboom/claude-automation
claude plugin install kanban-automation@vinnie-automation --scope user
```

### In a cloud session

The `/plugin` command does not exist in a cloud session. Put these three
lines in the setup script of the environment instead:

```sh
claude plugin marketplace add Vinnehboom/claude-automation
claude plugin marketplace update vinnie-automation
claude plugin install kanban-automation@vinnie-automation --scope user
```

CAUTION: Add this repository as a source on the ENVIRONMENT, not on one
session. The add step clones it through the git proxy of the session, and
that proxy allows only the repositories attached to the session. A public
repository is not reachable for that reason alone. Without this source,
the clone fails and the install reports `Plugin "kanban-automation" not
found in marketplace "vinnie-automation"`. That message names the plugin,
so it reads like a stale marketplace. It is an empty one.

Do not put `|| true` on these lines. The first two do the network work.
If one of them fails and the script hides the failure, the only error you
see is the third line's, and that error names the wrong cause.

Use `--scope user`. `--scope project` writes the two keys into the
project's tracked `.claude/settings.json`, which then shows as an
uncommitted change in every session.

Trust the workspace when Claude Code asks for it. Other project settings,
such as permissions and hooks, load only after you trust the folder.

## Versions

`main` is the latest version of the plugin. A skill-only pull request
merges to `main` without a review, so a project that installs from `main`
gets each change at its next session start.

A project that must not change pins a release branch instead. Each
release branch is named `release/kanban-automation-<major>.<minor>` and
starts at the commit that shipped that version.

| Ref | Version | Content |
| --- | --- | --- |
| `main` | latest | The current skills, including the changes for Project threads |
| `release/kanban-automation-0.1` | 0.1.0 | The generational orchestrator: `kanban-cycle`, `ticket-pipeline`, `handoff`, `coding-style` as of 2026-09-25 |

### Pin a project to a release

Add the ref to the marketplace source in the setup script, after a `#`:

```sh
claude plugin marketplace add 'Vinnehboom/claude-automation#release/kanban-automation-0.1'
claude plugin marketplace update vinnie-automation
claude plugin install kanban-automation@vinnie-automation --scope user
```

`marketplace update` stays on the pinned ref. To follow the latest
version, write the source without a `#` suffix.

The pin belongs to the environment, not to the project, because the
setup script installs the plugin. Two projects that share one
environment get the same version. If one project must follow `main`
and another must stay pinned, give them separate environments.

### Rules for a release branch

- Merge to a release branch only a fix for a project that stays on it.
  Do not merge new features there.
- Change `version` in `plugins/kanban-automation/.claude-plugin/plugin.json`
  when a release branch starts, and when a change on `main` breaks a
  pinned project. The version names the release. It does not select it.
- Keep a release branch until no environment pins it.

## Skill names change after the install

A plugin gives its skills a namespace. `/kanban-cycle` becomes
`/kanban-automation:kanban-cycle`. Before you remove a skill from a
project's `.claude/skills/`, change every Routine prompt that calls it by
the old name.
