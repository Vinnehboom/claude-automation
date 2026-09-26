# The ticket PR body

Every PR that this pipeline opens uses the body below. If the repository
has its own PR template, the repository template wins (see "Opening the
PR" in `SKILL.md`). Write the body with the `simple-english` skill when
the project supplies it.

Keep the section headings exactly as they are. Fill each section from the
source named in the table. If a section has nothing to say, write one line
that says so. Do not delete the heading.

| Section | Source | Written at |
|---|---|---|
| What | The final diff | PR open |
| Why | The ticket card and the plan's Goal | PR open |
| Assumptions | The plan's Decisions and Risks, and the Checkpoint 1 answers | PR open |
| Findings | The Reviewer's verdict and the result of the fix pass | PR open, then each review round |
| Testing evidence | The commit gate, CI, and the Gatekeeper's UI capture | PR open, then the Gatekeeper |

## Template

Replace every `<...>` placeholder. Put a harness-required attribution
block, if there is one, above the first heading. Add no Claude trailer and
no "Generated with Claude Code" footer.

```markdown
## What

<Two to five sentences, or a short list. Tell what a user or a developer
sees after this change. Name the main files or routes only when that helps
the reader.>

## Why

Ticket: [<TASK_ID> — <ticket name>](<Notion card URL>)

<One to three sentences from the ticket's goal. The full plan is on the
card. Do not link a repository file for the plan.>

<If the PR is stacked: "Stacked on #<number>. Merge that PR first.">

## Assumptions

- <Each decision that the ticket did not state and that the plan or
  Checkpoint 1 settled. Tell who settled it: "Vinnie, at Checkpoint 1" or
  "the planner".>
- <Each fact that the change relies on and that the tests do not prove.>

## Findings

Review: <APPROVE | <n> blocking, <m> non-blocking>, one round, blind reviewer.

- <Each blocking finding, and the commit that fixed it or "still open".>
- <Each non-blocking finding, one line, and "fixed" or "left as is" with the reason.>
- <Anything the developer found during the work that is outside this
  ticket: a bug, a gap in the docs, a follow-up ticket.>

## Testing evidence

- Specs: <the specs added or changed, and the command the commit gate ran>.
- CI: <the state of CI on the head commit, if known>.

Visual evidence: pending the Gatekeeper.
```

## Rules for each section

- **What** tells what changed, not how the pipeline ran. No phase names.
- **Why** always has the ticket link.
- **Assumptions** is the section that a reviewer reads to find a wrong
  guess. Put every guess there. An assumption that is also a risk gets
  the word "Risk:" at the start of its line.
- **Findings** replaces the separate "review outcome" line. The full text
  of each finding still goes to the PR as review comments (see "Opening
  the PR", step 6). This section is the summary.
- **Testing evidence** keeps the `Visual evidence: pending the
  Gatekeeper.` line until the Gatekeeper replaces it (Phase 5, step 2).
  The Gatekeeper puts the capture images in this section. They show
  inline in the PR, from the repository's `evidence` branch.

When a review round changes the branch, update **Findings** and
**Testing evidence** with `mcp__github__update_pull_request`. Keep the
earlier rounds as lines. Do not rewrite them.
