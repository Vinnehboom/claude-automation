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

1. Add the marketplace and the plugin to `.claude/settings.json` of the
   project:

```json
{
  "extraKnownMarketplaces": {
    "vinnie-automation": {
      "source": { "source": "github", "repo": "Vinnehboom/claude-automation" }
    }
  },
  "enabledPlugins": { "kanban-automation@vinnie-automation": true }
}
```

2. If you work in a terminal, run
   `/plugin install kanban-automation@vinnie-automation`.
3. If the project runs in a cloud session, add this command to the setup
   script of the cloud environment:

```
claude plugin install kanban-automation@vinnie-automation --scope project
```

4. Trust the workspace when Claude Code asks for it. Project settings load
   only after you trust the folder.

NOTE: The `/plugin` command does not exist in a cloud session. A plugin
from an external source also does not load from `enabledPlugins` alone.
The setup script of the environment does the install instead.

## Skill names change after the install

A plugin gives its skills a namespace. `/kanban-cycle` becomes
`/kanban-automation:kanban-cycle`. Before you remove a skill from a
project's `.claude/skills/`, change every Routine prompt that calls it by
the old name.
