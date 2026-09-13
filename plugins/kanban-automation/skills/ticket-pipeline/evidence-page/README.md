# The evidence page

`page.html` is the source of one ticket's evidence page. Each ticket that
the `ticket-pipeline` skill carries through the Gatekeeper phase gets its
own copy of this page, published as its own Artifact. The Gatekeeper
publishes it once and republishes the same URL on every later round for
that ticket. See `ticket-pipeline/SKILL.md`, Phase 5, for when and how.

## What the page does

The page holds no state of its own. It reads two things from the
artifact's own document store and shows them:

- `meta/info` — one document: `{ticket, repo}`. Cosmetic only (the page
  header and the browser tab title); its absence does not stop the page
  from showing rounds.
- `rounds` — one document per Gatekeeper run for this ticket, id `"1"`,
  `"2"`, and so on. Read in order by the `round` field. See "Round shape"
  below.

The page never deletes a round and never edits an old one. A capture
failure, a review round, and the pull request merging all show up as new
history, not as a change to what came before.

## Round shape

One `rounds/<n>` document:

```json
{
  "round": 1,
  "at": "2026-09-14T10:03:00Z",
  "pr": { "number": 142, "url": "https://github.com/Vinnehboom/claude-automation/pull/142" },
  "branch": "ticket/h-12-evidence-page",
  "commit": "3a71f9c2b1e04d9f6a8c1b2d3e4f5061728394a5",
  "ci_state": "success",
  "outcome": "clean",
  "findings": {
    "blocking": [],
    "non_blocking": ["The contact sheet omits the mobile viewport for one page."]
  },
  "files": [
    { "name": "contact-sheet-desktop", "viewport": "desktop", "kind": "contact-sheet", "path": "images/H-12-r1-desktop-contact-sheet.png", "status": 200 },
    { "name": "admin-score-modifier", "viewport": "desktop", "kind": "still", "path": "images/H-12-r1-admin-score-modifier.png", "status": 500 }
  ]
}
```

- `outcome` is one of `clean`, `tooling_failure`, or `blocked` — the same
  three cases `run.sh`'s exit codes and manifest statuses already
  distinguish (see `scripts/ui_capture/README.md`). The page colors the
  round's chip from it.
- `ci_state` is whatever the pull request's check-suite status reads as
  at the moment of this round: `success`, `failure`, `pending`, or
  similar. Optional — omit it when it is not known.
- `findings` is present only on a round that follows a finished review.
  Every string in `blocking` and `non_blocking` is the reviewer's own
  finding text, unedited.
- `files` lists only what the round makes visible: a contact sheet, a
  core page that answered with an error status, or a ticket-specific
  target. It does not list a core still that is only visible folded into
  its contact sheet.
- `path` in each file entry is a path published alongside this page in
  the SAME Artifact version, under `images/`. It is never a bare
  filename and never an external URL — see "File naming" below.

## File naming

Every image or video this page shows is published as an ordinary file
next to `page.html`, named:

```
images/<ticket>-r<round>-<name>.<extension>
```

For example, `images/H-12-r1-desktop-contact-sheet.png`. The ticket
anchors the name, not the pull request number, because one ticket can
span more than one pull request or review round. A later round's publish
call never repeats an earlier round's file names in its own `files` map
— the Artifact tool keeps a file that a publish does not mention, so
nothing here is ever deleted by a later round.

## The `{{TICKET}}` placeholder

The checked-in file carries one substitution point, in its `<title>`
tag: `<title>PR evidence — {{TICKET}}</title>`. The Gatekeeper replaces
`{{TICKET}}` with the real ticket id in a plain string replace, once,
before the FIRST publish for a ticket. A later republish reuses the
Artifact tool's own title-stability rule (an HTML publish's `<title>`
tag is authoritative and the artifact keeps its name across redeploys),
so this substitution never runs a second time for the same ticket.

## To publish

The Gatekeeper publishes with `capabilities: {db: {}}` on the FIRST
publish for a ticket, and omits `capabilities` on every later
republish for that same ticket — an omitted `capabilities` on a
redeploy keeps the stored declaration, which is what this page needs
to keep working.

Do not publish this file without `url` once a ticket already has one.
A publish without it creates a second, disconnected page — the ticket
card's link, and every earlier round's history, then point at a page
nothing updates.
