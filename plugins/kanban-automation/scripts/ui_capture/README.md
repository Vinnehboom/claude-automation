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
  "boot_command": "${CLAUDE_PLUGIN_ROOT}/scripts/ui_capture/boot.sh",
  "core_targets_command": "script/ui_capture/core_targets.sh",
  "boot": {
    "build_commands": ["npm run build", "npm run build:css"],
    "db_credentials_command": "…",
    "db_setup_commands": ["…", "…"],
    "server_command": "… -p {port} -P {pidfile} …",
    "health_path": "/up",
    "hydrate_files": ["config/credentials/test.key"],
    "run_suffix_env_var": "TEST_ENV_NUMBER"
  },
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

A project can write its own `boot_command` script, or point it at
`boot.sh` below, the harness this plugin ships.

### `boot.sh`, the generic boot harness

Point `boot_command` at `${CLAUDE_PLUGIN_ROOT}/scripts/ui_capture/boot.sh`
to use this harness instead of a project-owned script. It does the part of
booting an app that has nothing to do with the app's own framework: finds
a free port, starts the server, waits for a pidfile, polls a health path,
retries three times if the port turns out taken, hydrates a dispatch
worktree from the main checkout, drops and recreates a per-run database
named by a suffix, writes a state file, tears the run down from it later,
and cleans up on any failure — even one before `--stop` is ever called.

It reads seven values from the project's `.claude/ui-capture.json`, under
a `boot` key. Five are required: `db_credentials_command`, `db_setup_commands`,
`server_command`, `health_path`, and `run_suffix_env_var`. The other two,
`build_commands` and `hydrate_files`, are optional — a project with no
build step or nothing to hydrate can either omit the key or set it to an
empty array; the harness treats both the same.

| Key | What it is |
|---|---|
| `build_commands` | An array of shell commands. Run once, in order, before the database step. |
| `db_credentials_command` | A shell command. Must print exactly one line, nothing else on stdout: `name\|username\|password`, for a PostgreSQL database reachable at `127.0.0.1`. Only the last line of its output is read, so a stray line before it (a deprecation warning, for example) does not break the parse. |
| `db_setup_commands` | An array of shell commands. Run in order, with the run-suffix variable (see below) exported, after the harness drops any database left over from an earlier run of the same ticket. Together they create and seed this run's own database. |
| `server_command` | A shell command with two placeholders, `{port}` and `{pidfile}`. The harness fills both in. The command must start the server in the background on its own (for example, a `-d` flag) and write its own process ID to the file at `{pidfile}` before it returns. This is a hard requirement, not a nicety: a command that backgrounds a process without writing `{pidfile}` leaks that process on any retry or teardown path, since the harness has no other way to identify it. |
| `health_path` | A path, for example `/up`. The harness polls `<server URL><health_path>` with `curl -f`, which does not follow redirects and treats any response under 400 as ready — a page that redirects (302) counts as healthy, not just a literal `200`. |
| `hydrate_files` | An array of paths, relative to the project root, that a dispatch worktree may lack. The harness copies each one from the main checkout when the worktree does not already have it. `node_modules` is not on this list — the harness always symlinks it from the main checkout on its own, since every project on this driver already needs Node for `capture.mjs`. |
| `run_suffix_env_var` | The name of the environment variable that carries the run's database suffix, for example `TEST_ENV_NUMBER`. The harness exports it, under this name, before `db_setup_commands` and before `server_command`, and again as the second line of its own stdout on success. |

A project whose boot procedure does not fit this shape — a boot that needs
a branch or a loop, for example — keeps `boot_command` pointing at its own
script instead. This harness only runs when a project's `boot_command`
names this file.

`boot_command` runs inside a fresh `sh -c`, not inside `run.sh`'s own
shell. `run.sh` exports `${CLAUDE_PLUGIN_ROOT}` before invoking it so that
child shell can resolve the variable too, whether or not the process that
started `run.sh` set it.

See `boot-config.example.json` for a worked `.claude/ui-capture.json` that
uses the harness.

The database step assumes PostgreSQL: the harness drops the run's database
with `dropdb` on the command line, reading the connection details from
`db_credentials_command`, both before `db_setup_commands` runs and again
on teardown. Creating and seeding the database is `db_setup_commands`'s own
job, not the harness's. A project on a different database engine needs its
own `boot_command` script instead.

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
    { "name": "score-modifiers-index", "kind": "still", "path": "/admin/score_modifiers" },
    { "name": "create-score-modifier", "kind": "video", "path": "/admin/score_modifiers/new",
      "steps": [{ "action": "fill", "selector": "#score_modifier_value", "value": "5" },
                { "action": "click", "selector": "input[type=\"submit\"]" }] } ] }
```

A `still` target is a page, nothing more: a `name`, `kind`, a `path`, and
optionally `signed_out: true`. A `video` target adds `steps`: an ordered
list of `{action, selector, value}` entries, `action` one of `click`,
`fill`, `wait_for`, `press` (`value` applies to `fill` and `press` only).
Each video gets its own browser context, at each viewport, and completes
when that context closes — one WebM file per viewport, VP8 at 25 frames
per second.

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

An entry with no `file` is always `"attach": false`. The Gatekeeper
publishes every entry whose `attach` is true and whose `file` is not
null to the ticket's evidence page (see the `ticket-pipeline` skill's
`evidence-page/README.md`).

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
- `boot.sh --ticket <id> [--dir <path>] [--stop]` — the generic boot
  harness described above. A project opts in by pointing its own
  `boot_command` at this file.
- `example.json` — a worked example of the Capture plan shape, for the
  planner and the developer to copy from.
- `boot-config.example.json` — a worked `.claude/ui-capture.json` that uses
  the harness, for a project adopting it to copy from.
- `test/run_tests.sh` — the boot/run suite described above.
- `test/capture_logic_test.mjs` — a `node --test` suite for `capture.mjs`'s
  pure logic (the step dispatch, the attach rule, the sign-in-bounce
  check). Nothing that drives a real browser is covered here. Run it with
  `NODE_PATH="$(npm root -g)" node --test scripts/ui_capture/test/capture_logic_test.mjs`.

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
- `boot.sh` also needs `node` (it finds a free port with one), `curl` (it
  polls the health path with one), and `dropdb` on the command line,
  against a PostgreSQL server reachable at `127.0.0.1`.
- `boot.sh` needs bash 4 or newer (`mapfile`) and git 2.31 or newer
  (`--path-format=absolute`).
