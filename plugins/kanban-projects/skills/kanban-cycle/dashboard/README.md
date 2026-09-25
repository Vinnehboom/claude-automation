# The dashboard page

`board.html` is the source of the live status board. The board is a
published Artifact. Its URL is `dashboard_artifact_url` in
`.claude/kanban-cycle.json`.

This file is a copy, kept for repair. The live page is the published
artifact, not this file.

## What the page does

The page holds no state. It reads one collection from the artifact's
document store, `state`, and shows one section per document. Each
project writes `state/<project_key>` under its own key. The section
shows three things:

- Card counts by status, as one bar.
- Progress per epic.
- Pull requests merged per week, split into ticket work and automation
  upkeep.

The page also shows how old each snapshot is. A snapshot older than
eight days gets a "A cycle was missed" chip, because cycles run weekly.

Step 7 of `../SKILL.md` gives the field-by-field shape of the document.
That step is the contract. If you change a field name here, change it
there in the same commit.

The page also carries a fallback snapshot, in the `FALLBACK` constant.
The page shows the fallback for the first moment after load, and
whenever the document store does not answer. A banner marks it, with the
date it was captured.

## Colors in the throughput chart

The two series use `--s-ticket` and `--s-maint`. Both pairs come from
the ASD validator in the `dataviz` skill. The dark pair passes every
check. The light pair sits in the CVD floor band, which is allowed only
with a second signal, so the chart also carries a legend, a value label
on each bar, and a 2 px gap between the two segments. Keep all three if
you change the colors, or revalidate the pair first.

## To repair or change the page

1. Edit `board.html`.
2. Publish it with the `Artifact` tool. Pass `url` set to
   `dashboard_artifact_url`, and the same file path.
3. Do not pass `capabilities`. An omitted `capabilities` keeps the `db`
   declaration that the page needs.

CAUTION: Do not publish this file without the `url` parameter. A publish
without it creates a second board at a new URL. Vinnie's bookmark, and
every project that writes to the first board, then point at a board that
no cycle updates.
