---
name: kanban-cycle
description: >-
  Run one scheduled cycle of a project's Notion kanban board from the
  weekly cycle thread of a Claude Project: find stuck ticket threads,
  count room under the PR caps, pick the next ready ticket and ask the
  project coordinator to start a ticket thread for it, merge whitelisted
  maintenance PRs that no thread owns, and write the dashboard snapshot.
  Ticket threads own their own PRs (CI fixes, review rounds, rebases,
  merges), so this skill does not triage them. Reads its repo, board,
  and caps from `.claude/kanban-cycle.json`. Fired by the two Routines of
  the current cycle thread, which is replaced every Monday. Use when a
  Routine or the user says "run the board cycle" or "/kanban-cycle". Do
  not use for a one-off "work this ticket" request: that is
  /ticket-pipeline in its own thread.
---

# Kanban cycle

One pass of: see what the ticket threads are doing, then fill free room
with the next ready ticket. The cycle thread does no ticket work itself.
It runs when nobody watches, so it must raise what needs Vinnie, and it
must stay quiet when nothing does. Step 7 says which cycles post.

## Where the work lives

| Who | Owns |
| --- | --- |
| The project coordinator | Starting threads. Project memory. Only the coordinator can start a thread. |
| A ticket thread | One ticket from plan to merge and Curator, with `/ticket-pipeline`. It subscribes to its own PR, so CI and review events wake it directly. |
| The cycle thread (this skill) | Picking work, finding stuck threads, the dashboard, and the weekly rollover. |
| A maintenance thread | A config or automation PR with no ticket. It drives its own PR like a ticket thread does. |

## 0. Load config

Read `.claude/kanban-cycle.json`: `repo`, `notion_board_url`,
`max_open_prs`, `min_open_prs`, `max_stacked_prs`,
`maintenance_automerge_paths`, `externally_owned_ticket_ids`,
`project_key`, and `dashboard_artifact_url`. If the file is missing, say
so and stop. Do not guess a repo or a board.

Keys that the old generational orchestrator used
(`orchestrator_cost_ceiling_usd`, `orchestrator_branch`,
`cycle_log_keep`) are not used here. Ignore them.

## 0b. Two repositories

| Repository | Holds | How a change lands |
| --- | --- | --- |
| The project repo (`repo` in the config) | Product code, `.claude/*.json` config, `.claude/settings.json`, the session-start hook | A normal PR |
| `Vinnehboom/claude-automation` | The `kanban-automation` plugin | A PR there. Attach the repo with `add_repo` first. |

A direct push to `main` is blocked in both repositories. Push a branch
and open a PR.

**Auto-merge in the automation repository.** A PR there merges without a
review when both conditions are true:

- Every changed path is under `plugins/*/skills/**`.
- A check named `validate` ran on the head commit and passed. No check
  run is not a pass.

Everything else in that repository waits for Vinnie: the manifests, the
README, and the workflows. The mirror of this rule in the project
`CLAUDE.md` is what the classifier reads. If the grant changes, change
both.

A skill change on `main` reaches every project that follows `main`.
Projects that must not change pin a release branch (see the README,
"Versions"). A lesson about one project belongs in that project's
config or `CLAUDE.md`, not in a skill.

## 1. Read real state

Do not trust the conversation of this thread as a record. Read:

1. **The board.** Query `notion_board_url` for every card and its
   Status, Priority, Epic, and `Depends On`.
2. **Open PRs.** `list_pull_requests` (state open) on `repo`. For each
   PR, note the number, the base branch, the linked ticket (a Notion card
   link in the body), CI state, and review state. When the PR numbers are
   already known from an earlier cycle in this thread, use
   `pull_request_read` per PR (`get_status`, `get_reviews`) instead. Those
   responses carry no PR body, and PR bodies are long.
3. **Threads.** `list_thread_sessions`. Match each ticket thread to its
   ticket by its title or its root message. Read `status_bucket`
   (working, blocked, review_ready, completed, failed) and
   `last_activity_at`.

Skip every ticket in `externally_owned_ticket_ids` in all steps below.
A session outside this Project drives it. Do not count its PR toward the
caps. Remove an id from that list only on Vinnie's word.

## 2. Find stuck work

A ticket thread is stuck when one of these is true:

- Its PR has red CI or a merge conflict, and the thread has had no
  activity since the failure.
- Its `status_bucket` is `failed`, or `worker` is `disconnected`.
- It waits on Vinnie (a checkpoint card or a question) for more than 48
  hours.
- A card is "In progress" or "Review" and no thread owns it.

For a thread that failed or went quiet on red CI, send it a short
`send_message` that names the problem. For a question that waits on
Vinnie, do not ask it again here: list it in the rundown with a link to
its thread. For a card that no thread owns, ask the coordinator to start
a thread for it (step 5).

Do not fix a PR from this thread. The thread that owns it fixes it.

## 3. Maintenance PRs that no thread owns

A PR with no linked ticket, opened by an earlier orchestrator or cycle,
can have no owning thread. If its entire diff is inside
`maintenance_automerge_paths` (check with `get_files`: one file outside
the list disqualifies the PR) and CI is green, mark it ready and merge it
with `merge_method: "rebase"`. Then tell the ticket threads with an open
PR, with `send_message`, that `main` moved, so that each one rebases its
own branch.

Leave every other PR with no ticket alone, and list it in the rundown.
Never merge a PR that Vinnie opened by hand.

## 4. Compute room

```
open_count    = open PRs that link a ticket card
stacked_count = ticket-linked open PRs whose base is not the default branch
```

Maintenance PRs and PRs in the automation repository count toward
neither number.

A ticket thread with no PR yet (planning, or waiting at Checkpoint 2)
counts as in flight. Only one ticket can be in that state at a time. If
one is, start no new ticket this cycle.

- If `open_count >= max_open_prs`, start no new ticket.
- Otherwise there is room. A ticket that must stack on an open PR can
  start only if `stacked_count < max_stacked_prs` and that PR has had
  Vinnie's first review.
- If `open_count < min_open_prs` and ready tickets exist, start enough to
  reach the floor, never past `max_open_prs`.

## 5. Pick the next ticket and ask for its thread

Candidates are cards with Status "Not started" whose `Depends On` is
satisfied (the dependency is Done, or its PR is open and can be stacked
on per step 4). Rank by priority. Take the first candidate that clears
step 4.

This thread cannot start a thread. Send the coordinator one
`send_message` (session id from `get_channel_session_id`) that asks for a
ticket thread, with this brief:

```
Start a ticket thread for <Task ID> — <card title> (<card URL>).
Run /kanban-automation:ticket-pipeline <Task ID> in Project-thread mode.
Base branch: <main, or the dependency's branch and PR number>.
```

Start at most one ticket per cycle, except to reach `min_open_prs`. If no
candidate clears step 4, that is a valid result. Say so in the rundown.

## 6. Update the dashboard — every cycle, quiet ones included

`dashboard_artifact_url` in `.claude/kanban-cycle.json` is a published
Artifact. It shows two things for each project: board progress (card
counts and epics) and merge throughput by week. Open pull requests,
running work, and questions for Vinnie do not go on the board. The
Project thread that owns the work reports them.

**One board serves every project.** The same artifact URL goes in every
project's `kanban-cycle.json`. Each project writes only its own
document, keyed by `project_key`.

The page holds no state. It renders what the cycles last wrote to the
artifact's document store, so **one write is the entire update**. Do not
republish the HTML. Use the `ArtifactData` tool (`set`, collection
`state`, document `<project_key>`, the configured `url`). The first write
from a new cycle thread can need an `Artifact` `read` of the URL first.

**This step runs on every cycle, including a quiet one.** The page marks
a project whose snapshot is older than eight days with "A cycle was
missed".

### What to write

It is a full replace, so send the whole document every time:

- `project` — `{key, name, repo, board_url}`. Constant per project. Send
  it every time, so the page can name the project without a registry.
- `as_of` — RFC 3339, now. The page shows its age next to the project
  name.
- `board` — `{totals: {done, review, in_progress, not_started}, epics:
  [{name, done, total}]}`, from step 1's board query. Put cards with no
  epic in one `No epic` entry.
- `throughput` — `{weeks: [{week, total, ticket}], ticket_median_hours,
  ticket_count, maintenance_count}`. `week` is the Monday of that week,
  `YYYY-MM-DD`. `total` counts every merged PR, `ticket` only the
  ticket-linked ones. Recompute it from merged PRs when a PR merged since
  the last cycle. Otherwise read the stored document first (`get`) and
  carry `throughput` forward unchanged. The page fills weeks with no
  merges itself, so do not write zero weeks.

Do not write `cycles/`, `answers/`, `requests/`, or `retractions/`
documents. The page no longer reads them.

**Never publish a new artifact for this board.** Every project that
writes to the board points at `dashboard_artifact_url`. If the URL is
missing from the config, say so in the rundown and carry on.

## 7. Post only when the cycle is worth raising

A cycle is **worth raising** when one of these is true:

- Something needs Vinnie's decision, answer, or review, and he has not
  seen it yet.
- A ticket thread was requested, a maintenance PR merged, or a thread is
  stuck.

Otherwise the cycle is **quiet**. End a quiet cycle with an
`update_status` refresh and `no_reply_needed`. Do not post.

When the cycle is worth raising, post one `reply` in this thread. Give
one line per item, and link the ticket card, the PR, or the thread
(`[title](#cmsg_…)`). Do not list what the ticket threads already
reported in their own threads. End with the dashboard link. Post one
reply per cycle, never more.

## 8. Weekly rollover

A cycle thread lives for one week, so its context stays small.

On the Monday 08:00 firing, before step 1:

1. Send the coordinator a `send_message` that asks it to start next
   week's cycle thread, with this thread's Routine prompt as the brief.
2. Run this cycle as normal.

The new thread, on its first turn:

1. Makes sure that `kanban-automation:*` skills are loaded. If they are
   absent, it stops, changes nothing, and says so. The old thread keeps
   its Routines.
2. Creates its two Routines (`create_trigger`, same names, same crons,
   same prompt, `persistent_session_id` set to its own session id).
3. Makes sure with `list_triggers` that both exist and name it.
4. Only then deletes the old thread's two Routines. Create before delete,
   so a failure leaves the cycle running.

The count of cycle Routines for this project must be the same before and
after the rollover.

## Environment facts

- **Local `HEAD` can go stale.** It has reverted to an old commit after a
  push, and the remote-tracking ref went stale with it. Before a merge or
  a report that depends on branch state, `git fetch origin <branch>` and
  compare against the fetched ref. Never `--force` over a rejected push.
- **`circleci.com` is not reachable.** The network proxy blocks it. Read
  the commit status and `.circleci/config.yml` instead of the job log.

## Guardrails

- Never act on a ticket or PR in `externally_owned_ticket_ids`.
- Never fix, rebase, or push to a PR that a ticket thread owns. Tell that
  thread instead.
- Never exceed `max_open_prs` or `max_stacked_prs`. Both count
  ticket-linked PRs only. Never stack on a PR that Vinnie has not
  reviewed once.
- One ticket in the pre-Checkpoint-2 state at a time.
- No merge commits. Every merge uses `merge_method: "rebase"`.
- Merge a PR with no ticket only per step 3. Never widen
  `maintenance_automerge_paths`.
- Update the dashboard on every cycle. Write only `state/<project_key>`
  of this project, and only at `dashboard_artifact_url`.
- One reply per cycle at most. A quiet cycle posts nothing.
- In the rollover, create the new Routines before you delete the old
  ones.
