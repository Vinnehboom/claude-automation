#!/usr/bin/env bash
# Synthetic test suite for boot.sh / run.sh's argument handling. Runs
# boot.sh against a throwaway project directory, a fake server
# (fake_server.mjs) standing in for a real app, and a mock `dropdb` on
# PATH standing in for PostgreSQL -- no real database or app required.
#
# Run it directly:
#   plugins/kanban-automation/scripts/ui_capture/test/run_tests.sh
#
# Exits 0 if every check passes, non-zero (and prints which check failed)
# otherwise. Scenarios that wait on a health check or a retry timeout take
# real wall-clock time; the whole suite runs in well under two minutes.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UI_CAPTURE_DIR="$(dirname "$SCRIPT_DIR")"
BOOT_SH="$UI_CAPTURE_DIR/boot.sh"
RUN_SH="$UI_CAPTURE_DIR/run.sh"
FAKE_SERVER="$SCRIPT_DIR/fake_server.mjs"

export PATH="$SCRIPT_DIR/mock_bin:$PATH"

PASS=0
FAIL=0
CURRENT=""

section() {
  CURRENT="$1"
  echo ""
  echo "== $1 =="
}

ok() {
  PASS=$((PASS + 1))
  echo "  ok: $1"
}

fail() {
  FAIL=$((FAIL + 1))
  echo "  FAIL ($CURRENT): $1"
}

assert_eq() {
  if [ "$1" = "$2" ]; then ok "$3"; else fail "$3 (expected '$2', got '$1')"; fi
}

assert_true() {
  if eval "$1"; then ok "$2"; else fail "$2 (condition: $1)"; fi
}

# ---------------------------------------------------------------------------
# One throwaway project per scenario, so runs never interfere with each
# other. Not a git repo on purpose: boot.sh falls back to $(pwd) when
# `git rev-parse --show-toplevel` fails, which is exactly what a project
# without a main checkout to hydrate from should look like too.
# ---------------------------------------------------------------------------
new_project() {
  local dir
  dir="$(mktemp -d)"
  mkdir -p "$dir/.claude" "$dir/node_modules"
  echo "$dir"
}

# $1 = project dir, $2 = server_command template, $3 = build_commands JSON array,
# $4 = db_setup_commands JSON array, $5 = extra top-level MISSING keys to omit ("" for none)
write_config() {
  local dir="$1" server_cmd="$2" build_cmds="$3" db_setup_cmds="$4" omit="$5"
  local db_cred_cmd="printf 'DEPRECATION WARNING: ignore me\ntestdb|testuser|testpass\n'"
  jq -n \
    --arg boot_command "$BOOT_SH" \
    --arg core_targets_command "echo '[]'" \
    --arg server_command "$server_cmd" \
    --arg db_credentials_command "$db_cred_cmd" \
    --argjson build_commands "$build_cmds" \
    --argjson db_setup_commands "$db_setup_cmds" \
    --arg health_path "/health" \
    --arg run_suffix_env_var "TEST_ENV_NUMBER" '
    { boot_command: $boot_command,
      core_targets_command: $core_targets_command,
      boot: ({
        build_commands: $build_commands,
        db_credentials_command: $db_credentials_command,
        db_setup_commands: $db_setup_commands,
        server_command: $server_command,
        health_path: $health_path,
        hydrate_files: [],
        run_suffix_env_var: $run_suffix_env_var
      })
    }' > "$dir/.claude/ui-capture.json"

  if [ -n "$omit" ]; then
    jq "del(.boot.$omit)" "$dir/.claude/ui-capture.json" > "$dir/.claude/ui-capture.json.tmp"
    mv "$dir/.claude/ui-capture.json.tmp" "$dir/.claude/ui-capture.json"
  fi
}

server_cmd() {
  # $1 = --behavior value, remaining = extra fake_server.mjs flags
  local behavior="$1"; shift
  echo "node '$FAKE_SERVER' --behavior $behavior --port {port} --pidfile {pidfile} --health-path /health $*"
}

boot() {
  # $1 = project dir, $2 = run dir, $3 = ticket, remaining = extra boot.sh args
  local proj="$1" rundir="$2" ticket="$3"; shift 3
  ( cd "$proj" && "$BOOT_SH" --ticket "$ticket" --dir "$rundir" "$@" )
}

boot_stop() {
  local proj="$1" rundir="$2" ticket="$3"
  ( cd "$proj" && "$BOOT_SH" --ticket "$ticket" --dir "$rundir" --stop )
}

pid_alive() {
  kill -0 "$1" 2>/dev/null
}

# ---------------------------------------------------------------------------
# 1. Successful boot: build runs, credentials parse past a stray stdout
#    line (item 9), the run database is named distinctly per ticket (item
#    6), the server starts and answers healthy, and the state file carries
#    RUN_DB/SERVER_PID/BASE_URL as shell-quoted assignments (item 7).
# ---------------------------------------------------------------------------
section "boot: full success"
PROJ="$(new_project)"
RUNDIR="$(mktemp -d)"
export MOCK_DROPDB_LOG="$RUNDIR/dropdb.log"
: > "$MOCK_DROPDB_LOG"
MARKER="$RUNDIR/setup-ran"
write_config "$PROJ" "$(server_cmd normal)" '["true"]' "[\"printenv TEST_ENV_NUMBER >> '$MARKER'\"]" ""
OUT="$(boot "$PROJ" "$RUNDIR" H-14)"
RC=$?
assert_eq "$RC" "0" "exit code 0"
assert_true "echo \"$OUT\" | grep -q '^BASE_URL=http://127.0.0.1:'" "prints BASE_URL"
assert_true "echo \"$OUT\" | grep -q '^TEST_ENV_NUMBER=_h_14$'" "prints sanitized run-suffix line"
assert_true "[ -f '$RUNDIR/boot.env' ]" "state file exists"
assert_true "grep -q '^RUN_DB=testdb_h_14$' '$RUNDIR/boot.env'" "state file has unquoted-looking RUN_DB (%q of a plain word is itself)"
assert_true "grep -qE '^SERVER_PID=[0-9]+$' '$RUNDIR/boot.env'" "state file has SERVER_PID"
assert_true "grep -q '^BASE_URL=http://127.0.0.1:' '$RUNDIR/boot.env'" "state file has BASE_URL"
assert_true "[ -f '$MARKER' ] && grep -q '^_h_14$' '$MARKER'" "db_setup_commands saw the run-suffix env var"
SERVER_PID="$(grep '^SERVER_PID=' "$RUNDIR/boot.env" | cut -d= -f2)"
assert_true "pid_alive $SERVER_PID" "server process is actually running"
boot_stop "$PROJ" "$RUNDIR" H-14 >/dev/null 2>&1
sleep 0.3
assert_true "! pid_alive $SERVER_PID" "--stop killed the server"
assert_true "[ ! -f '$RUNDIR/boot.env' ]" "--stop removed the state file"
rm -rf "$PROJ" "$RUNDIR"
unset MOCK_DROPDB_LOG

# ---------------------------------------------------------------------------
# 2. --stop with nothing booted: exits 0, no error.
# ---------------------------------------------------------------------------
section "--stop: nothing to stop"
PROJ="$(new_project)"
RUNDIR="$(mktemp -d)"
write_config "$PROJ" "$(server_cmd normal)" '[]' '["true"]' ""
boot_stop "$PROJ" "$RUNDIR" H-99 >/dev/null 2>&1
assert_eq "$?" "0" "--stop with no state file exits 0"
rm -rf "$PROJ" "$RUNDIR"

# ---------------------------------------------------------------------------
# 3. Missing required key: named, exit 1.
# ---------------------------------------------------------------------------
section "missing config key"
PROJ="$(new_project)"
RUNDIR="$(mktemp -d)"
write_config "$PROJ" "$(server_cmd normal)" '[]' '["true"]' "db_credentials_command"
ERR="$(boot "$PROJ" "$RUNDIR" H-1 2>&1 1>/dev/null)"
RC=$?
assert_eq "$RC" "1" "exits 1"
assert_true "echo \"$ERR\" | grep -q 'db_credentials_command'" "names the missing key"
assert_true "[ ! -f '$RUNDIR/boot.env' ]" "no state file left behind"
rm -rf "$PROJ" "$RUNDIR"

# ---------------------------------------------------------------------------
# 4. Build failure: a failing build_commands entry aborts the boot, the
#    trap runs (this is a normal exit, not a SIGKILL), and no state file
#    or leftover run database is left for a later boot to trip over.
# ---------------------------------------------------------------------------
section "build failure"
PROJ="$(new_project)"
RUNDIR="$(mktemp -d)"
export MOCK_DROPDB_LOG="$RUNDIR/dropdb.log"
: > "$MOCK_DROPDB_LOG"
write_config "$PROJ" "$(server_cmd normal)" '["exit 3"]' '["true"]' ""
boot "$PROJ" "$RUNDIR" H-2 >/dev/null 2>&1
RC=$?
assert_true "[ '$RC' -ne 0 ]" "boot exits non-zero"
assert_true "[ ! -f '$RUNDIR/boot.env' ]" "cleanup trap removed the state file"
# RUN_DB isn't assigned until after the build step, so a build failure
# never reaches dropdb -- nothing queued to drop.
assert_true "[ ! -s '$MOCK_DROPDB_LOG' ]" "dropdb was never called (failed before RUN_DB existed)"
rm -rf "$PROJ" "$RUNDIR"
unset MOCK_DROPDB_LOG

# ---------------------------------------------------------------------------
# 5. Server retry exhaustion: the server keeps crashing before it answers
#    healthy. All three attempts run, boot.sh exits 2, and cleanup drops
#    the run database it had already created.
# ---------------------------------------------------------------------------
section "server retry exhaustion"
PROJ="$(new_project)"
RUNDIR="$(mktemp -d)"
export MOCK_DROPDB_LOG="$RUNDIR/dropdb.log"
: > "$MOCK_DROPDB_LOG"
write_config "$PROJ" "$(server_cmd crash-quick --delay 999 --die-after 2)" '[]' '["true"]' ""
START=$(date +%s)
ERR="$(boot "$PROJ" "$RUNDIR" H-3 2>&1 1>/dev/null)"
RC=$?
ELAPSED=$(( $(date +%s) - START ))
assert_eq "$RC" "2" "exits 2 after exhausting retries"
RETRIES="$(echo "$ERR" | grep -c 'retrying')"
assert_true "[ '$RETRIES' -ge 2 ]" "retried more than once ($RETRIES retry log lines)"
assert_true "[ ! -f '$RUNDIR/boot.env' ]" "cleanup trap removed the state file"
assert_true "grep -q 'testdb_h_3' '$MOCK_DROPDB_LOG'" "cleanup dropped the run database"
assert_true "[ '$ELAPSED' -lt 60 ]" "finished well inside a minute ($ELAPSED s) -- the crash-quick server dies fast enough that kill -0 breaks the poll early"
rm -rf "$PROJ" "$RUNDIR"
unset MOCK_DROPDB_LOG

# ---------------------------------------------------------------------------
# 6. Leak fix: sh -c "$SERVER_CMD" backgrounds the server, writes the
#    pidfile, then the launcher itself exits non-zero. Before this fix
#    that pidfile was never even looked at on this path.
# ---------------------------------------------------------------------------
section "retry-loop leak: launcher exits non-zero after backgrounding"
PROJ="$(new_project)"
RUNDIR="$(mktemp -d)"
export MOCK_DROPDB_LOG="$RUNDIR/dropdb.log"
: > "$MOCK_DROPDB_LOG"
write_config "$PROJ" "$(server_cmd write-pidfile-then-fail)" '[]' '["true"]' ""
boot "$PROJ" "$RUNDIR" H-4 >/dev/null 2>&1
RC=$?
assert_eq "$RC" "2" "exits 2 (every attempt takes this path)"
sleep 0.3
LEFTOVER="$(pgrep -f "fake_server.mjs --mode listen" || true)"
assert_eq "$LEFTOVER" "" "no fake-server listener process survives the run"
rm -rf "$PROJ" "$RUNDIR"
unset MOCK_DROPDB_LOG

# ---------------------------------------------------------------------------
# 7. run.sh / boot.sh usage errors don't crash on `set -u` when a flag is
#    given with no value -- they fall through to usage.
# ---------------------------------------------------------------------------
section "usage: flag with no value"
ERR="$("$BOOT_SH" --ticket 2>&1)"
RC=$?
assert_eq "$RC" "1" "boot.sh --ticket <nothing> exits 1"
assert_true "echo \"$ERR\" | grep -qi 'usage'" "boot.sh prints usage, not 'unbound variable'"
assert_true "! echo \"$ERR\" | grep -qi 'unbound variable'" "no raw unbound-variable crash"

ERR="$("$RUN_SH" --ticket H-1 --targets /nonexistent --out /tmp --budget 2>&1)"
RC=$?
assert_eq "$RC" "1" "run.sh --budget <nothing> exits 1"
assert_true "echo \"$ERR\" | grep -qi 'usage'" "run.sh prints usage, not 'unbound variable'"
assert_true "! echo \"$ERR\" | grep -qi 'unbound variable'" "no raw unbound-variable crash"

# ---------------------------------------------------------------------------
# 8. Ticket sanitization keeps distinct tickets distinct (item 6): the
#    exact line from boot.sh is extracted and exercised directly, so this
#    tracks the real implementation instead of a hand-copied guess at it.
# ---------------------------------------------------------------------------
section "ticket sanitization stays distinct"
SANITIZE_LINE="$(grep '^SANITIZED_TICKET=' "$BOOT_SH")"
sanitize() { TICKET="$1"; eval "$SANITIZE_LINE"; echo "$SANITIZED_TICKET"; }
A="$(sanitize 'H-14')"
B="$(sanitize 'H14')"
C="$(sanitize 'h.1.4')"
assert_true "[ '$A' != '$B' ] && [ '$A' != '$C' ] && [ '$B' != '$C' ]" "H-14 ($A), H14 ($B), h.1.4 ($C) sanitize to three different strings"

# ---------------------------------------------------------------------------
# 9. Double-boot guard (item 2): a second boot for a ticket that already
#    has a state file refuses, and leaves the first run untouched.
# ---------------------------------------------------------------------------
section "double-boot guard"
PROJ="$(new_project)"
RUNDIR="$(mktemp -d)"
export MOCK_DROPDB_LOG="$RUNDIR/dropdb.log"
: > "$MOCK_DROPDB_LOG"
write_config "$PROJ" "$(server_cmd normal)" '[]' '["true"]' ""
boot "$PROJ" "$RUNDIR" H-5 >/dev/null 2>&1
FIRST_PID="$(grep '^SERVER_PID=' "$RUNDIR/boot.env" | cut -d= -f2)"
FIRST_RUN_DB="$(grep '^RUN_DB=' "$RUNDIR/boot.env" | cut -d= -f2)"
ERR="$(boot "$PROJ" "$RUNDIR" H-5 2>&1 1>/dev/null)"
RC=$?
assert_true "[ '$RC' -ne 0 ]" "second boot for the same ticket refuses"
assert_true "echo \"$ERR\" | grep -qi 'stop'" "error tells the operator to stop the existing run first"
assert_true "pid_alive $FIRST_PID" "first run's server is still alive, untouched by the refused second boot"
assert_true "grep -q \"^RUN_DB=$FIRST_RUN_DB\$\" '$RUNDIR/boot.env'" "state file still names the first run's database"
boot_stop "$PROJ" "$RUNDIR" H-5 >/dev/null 2>&1
sleep 0.3
assert_true "! pid_alive $FIRST_PID" "--stop now cleans up the first run"
# The guard must not block a fresh boot once the previous one is stopped.
boot "$PROJ" "$RUNDIR" H-5 >/dev/null 2>&1
assert_eq "$?" "0" "a boot after a clean --stop succeeds again"
boot_stop "$PROJ" "$RUNDIR" H-5 >/dev/null 2>&1
rm -rf "$PROJ" "$RUNDIR"
unset MOCK_DROPDB_LOG

# ---------------------------------------------------------------------------
# 10. Incremental state file survives a SIGKILL (item 1): kill boot.sh
#     itself partway through -- after SERVER_PID is on disk but before the
#     health check (and the trap, which SIGKILL bypasses entirely) ever
#     runs -- and confirm --stop can still find and tear the run down.
# ---------------------------------------------------------------------------
section "state file survives a mid-boot SIGKILL"
PROJ="$(new_project)"
RUNDIR="$(mktemp -d)"
export MOCK_DROPDB_LOG="$RUNDIR/dropdb.log"
: > "$MOCK_DROPDB_LOG"
write_config "$PROJ" "$(server_cmd slow-health --delay 6)" '[]' '["true"]' ""
( cd "$PROJ" && "$BOOT_SH" --ticket H-6 --dir "$RUNDIR" >/dev/null 2>&1 ) &
BOOT_BG_PID=$!
# Give it time to get past build/db/port/pidfile and into the health poll,
# where SERVER_PID is already written but BASE_URL is not (the fake
# server isn't healthy for 6s).
sleep 2.5
assert_true "grep -q '^SERVER_PID=' '$RUNDIR/boot.env' 2>/dev/null" "SERVER_PID already on disk before the kill"
assert_true "! grep -q '^BASE_URL=' '$RUNDIR/boot.env' 2>/dev/null" "BASE_URL not written yet -- boot genuinely mid-flight"
SERVER_PID="$(grep '^SERVER_PID=' "$RUNDIR/boot.env" | cut -d= -f2)"
kill -9 "$BOOT_BG_PID" 2>/dev/null
wait "$BOOT_BG_PID" 2>/dev/null
assert_true "pid_alive $SERVER_PID" "server is still running -- the SIGKILL bypassed the cleanup trap, as expected"
assert_true "[ -f '$RUNDIR/boot.env' ]" "state file survived the SIGKILL"
boot_stop "$PROJ" "$RUNDIR" H-6 >/dev/null 2>&1
sleep 0.3
assert_true "! pid_alive $SERVER_PID" "--stop, run afterward, finds and kills the orphaned server"
assert_true "[ ! -f '$RUNDIR/boot.env' ]" "--stop removed the state file"
assert_true "grep -q 'testdb_h_6' '$MOCK_DROPDB_LOG'" "--stop dropped the run database recorded before the kill"
rm -rf "$PROJ" "$RUNDIR"
unset MOCK_DROPDB_LOG

# ---------------------------------------------------------------------------
echo ""
echo "== summary =="
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
