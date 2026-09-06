# UI capture

This directory boots a project's app, drives headless Chromium over it, and
produces screenshots for a pull request. The Gatekeeper phase of the
`ticket-pipeline` skill runs it before a pull request goes to review.

The driver is here. The three things that differ between projects are in
the project, in `.claude/ui-capture.json`.

## Run it

```sh
${CLAUDE_PLUGIN_ROOT}/scripts/ui_capture/run.sh \
  --ticket H-8 --targets tmp/ui-capture/H-8.json --out tmp/ui-capture/H-8 [--budget 600]
```

Always run it from the ticket branch's own checkout. `run.sh` captures
whatever code is checked out where you run it, not the branch named in
`--ticket`. The working directory decides which checkout gets captured, so
`--project-dir` exists only to override that.

`--targets` points at the ticket's Capture plan: the JSON file the
orchestrator writes from the plan's `## Capture plan` section. See
`example.json` for the shape. `run.sh` adds the app's core surface to this
list itself, from the project's `core_targets_command`. `--budget` is a
wall-clock limit in seconds. It defaults to 600.

## What the project supplies

`.claude/ui-capture.json`, in the project repository:

```json
{
  "boot_command": "script/ui_capture/boot.sh",
  "core_targets_command": "script/ui_capture/core_targets.sh",
  "sign_in": {
    "path": "/users/sign_in",
    "email_selector": "#user_email",
    "password_selector": "#user_password",
    "submit_selector": "input[type=\"submit\"]",
    "credentials_command": "…"
  }
}
```

If this file is absent, `run.sh` names it and stops with exit code 1. It
does the same for a missing key.

### `boot_command`

`run.sh` calls it two ways, and appends the arguments itself:

```
<boot_command> --ticket <id> --dir <out dir>
<boot_command> --ticket <id> --dir <out dir> --stop
```

The start form prints `KEY=value` lines on stdout. `BASE_URL` is required.
Every other line is exported into `core_targets_command` and into the
capture, so a project can pass on what its own boot established — a run
database suffix, a port, a token. The URL must be loopback. This capture
signs in with seeded credentials, so it never points at a deployed
environment.

The `--stop` form tears the same run down. `run.sh` calls it on every exit
path, a budget timeout and a kill included.

### `core_targets_command`

It prints a JSON array of targets on stdout. Anything it writes to stderr
is passed through, so a project can log the pages it left out. `run.sh`
stops with exit code 2 when the output is not a JSON array.

### `sign_in`

All five keys are required. A half-configured sign-in otherwise fails as a
browser timeout in the middle of the run, which reads as a broken page
instead of the configuration error it is.

`credentials_command` runs in the project directory and prints one
`email|password` line.

## What gets captured

- **The core surface**: whatever `core_targets_command` lists. A target it
  drops is that project's business, not this driver's.
- **The ticket's own targets**: the Capture plan the planner proposed and
  the developer amended. A target here whose `path` matches a core target
  replaces it, so a ticket can single out a page the core surface would
  otherwise fold into its contact sheet.

Every target is captured at two viewports: desktop (1440x900) and mobile
(390x844, `deviceScaleFactor: 3`, so the mobile PNG comes out at
1170x2532).

Every `signed_out` target is captured before the run signs in. Everything
else is captured signed in. A page that quietly bounces to the sign-in page
instead of rendering records as a tooling failure (`status: null`, with an
`error`), never as a false 200.

## Capture plan target shape

```json
{ "ticket": "H-8",
  "targets": [
    { "name": "score-modifiers-index", "kind": "still", "path": "/admin/score_modifiers" } ] }
```

A target is a page, nothing more: a `name`, `kind` (currently always
`"still"`), a `path`, and optionally `signed_out: true`.

## Contact sheets

A core surface can run to dozens of pages at two viewports. Rather than
attach each one at full size, `capture.mjs` lays every core still that
answered `200` into one grid per viewport (`contact-sheet.png`) with a
caption naming the page and its status, and marks those stills
`"attach": false` in the manifest.

Everything else is marked `"attach": true` and gets its own full-size file:

- Every ticket target, since that is the change under review.
- Any core page whose status is not `200`, or that failed outright
  (`status: null` with an `error`).
- Each contact sheet itself.

An entry with no `file` is always `"attach": false`. The Gatekeeper sends
every entry whose `attach` is true and whose `file` is not null.

## Exit codes

| Code | Meaning |
|---|---|
| 0 | Success. |
| 1 | Usage or configuration error (bad arguments, a missing or invalid `.claude/ui-capture.json`, a targets file that is not valid JSON). |
| 2 | The app did not boot, or the core surface did not resolve. |
| 3 | The capture itself failed (Chromium would not launch, a script error, a sign-in section that is incomplete). |
| 4 | The run did not finish inside its budget. |

A non-zero exit code here is a **capture failure**, and a capture failure
never blocks a pull request by itself. The one thing that does block is
different, and it is a test on field values: a capture that **succeeds**
and produces a manifest entry whose `status` is a number in the 5xx range.
A `null` status (paired with a non-empty `error`) is always a tooling
failure, whatever else is true about the entry.

## Files

- `run.sh` — the one command described above. Reads the project's config,
  wires the boot command to `capture.mjs`, merges the core surface with the
  ticket's targets, enforces the budget, and always tears the run down
  again. A `trap` on `EXIT`, `INT`, and `TERM` covers every exit path.
- `capture.mjs --targets <path> --out <dir> --base-url <url> --config <path>
  --project-dir <path>` — the Playwright driver. Writes
  `<out>/manifest.json` after every entry, so a budget timeout or a crash
  mid-run still leaves everything captured so far on disk.
- `example.json` — a worked example of the Capture plan shape, for the
  planner and the developer to copy from.

On exit, `<out>/result.json` lists every captured target and the overall
outcome in `exit_code` and `message`.

## Environment notes

- Chromium is the symlink at `/opt/pw-browsers/chromium`, launched with
  `--no-sandbox`. Do not run `playwright install`.
- The global `playwright` npm package supplies the driver. `run.sh` passes
  its location (`npm root -g`) to `capture.mjs` as `NODE_PATH`, since Node's
  ES module loader does not consult `NODE_PATH` on its own. `capture.mjs`
  reaches it through `createRequire`, which does.
- `jq` is required.
