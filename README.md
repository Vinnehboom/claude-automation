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
| `simple-english` | Writes technical text with the rules of ASD-STE100. |
| `coding-style` | Records a durable style preference into the style guide page of the project. |

## What each project supplies

The plugin reads these files from the project repository. Create them
before you enable the plugin:

- `.claude/kanban-cycle.json` — the repository, the board URL, and the caps.
- `.claude/knowledge-base.json` — the knowledge base, decisions, and tech debt pages.
- `.claude/coding-style.json` — the style guide page.

Each project also keeps its own session-start hook. That hook installs the
test environment of one project, so it cannot move into this plugin.

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
