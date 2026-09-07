#!/usr/bin/env bash
# Synthetic test suite for boot.sh / run.sh. Runs them against a
# throwaway project directory, a fake server (fake_server.mjs) standing
# in for a real app, and a mock `dropdb` on PATH standing in for
# PostgreSQL -- no real database or app required.
#
# Run it directly:
#   plugins/kanban-automation/scripts/ui_capture/test/run_tests.sh
#
# Exits 0 if every check passes, non-zero (and prints which check failed)
# otherwise.
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
TMP_DIRS=()

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

# A failing assertion doesn't stop the suite (assert_true/assert_eq never
# exit), but a crash partway through would otherwise leak temp dirs and
# fake-server processes -- catch that with a best-effort sweep on any exit.
cleanup_all() {
  pkill -f "$FAKE_SERVER" 2>/dev/null || true
  local d
  for d in "${TMP_DIRS[@]:-}"; do
    [ -n "$d" ] && rm -rf "$d"
  done
}
trap cleanup_all EXIT INT TERM

# ---------------------------------------------------------------------------
# One throwaway project/run directory per scenario, so runs never
# interfere with each other. Projects are not git repos on purpose:
# boot.sh falls back to $(pwd) when `git rev-parse --show-toplevel`
# fails, which is exactly what a project without a main checkout to
# hydrate from should look like too.
# ---------------------------------------------------------------------------
new_project() {
  local dir
  dir="$(mktemp -d)"
  TMP_DIRS+=("$dir")
  mkdir -p "$dir/.claude" "$dir/node_modules"
  echo "$dir"
}

new_rundir() {
  local dir
  dir="$(mktemp -d)"
  TMP_DIRS+=("$dir")
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

# $1 = project dir, $2 = jq filter (uses $v for the replacement), $3 = value
patch_config() {
  local proj="$1" filter="$2" value="$3"
  jq --arg v "$value" "$filter" "$proj/.claude/ui-capture.json" > "$proj/.claude/ui-capture.json.tmp"
  mv "$proj/.claude/ui-capture.json.tmp" "$proj/.claude/ui-capture.json"
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

# Same as boot(), but backgrounded with `exec` so `$!` afterward is
# guaranteed to be boot.sh's own pid -- a plain `( ... ) &` can leave $!
# naming the subshell instead, depending on whether bash's single-command
# subshell optimization kicks in, which would silently test nothing.
boot_bg() {
  local proj="$1" rundir="$2" ticket="$3"
  ( cd "$proj" && exec "$BOOT_SH" --ticket "$ticket" --dir "$rundir" ) &
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
#    line, the run database is named distinctly per ticket, the server
#    starts and answers healthy, and the state file carries RUN_DB /
#    SERVER_PID / BASE_URL.
# ---------------------------------------------------------------------------
section "boot: full success"
PROJ="$(new_project)"
RUNDIR="$(new_rundir)"
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
assert_true "grep -q '^RUN_DB=testdb_h_14$' '$RUNDIR/boot.env'" "state file has RUN_DB"
assert_true "grep -qE '^SERVER_PID=[0-9]+$' '$RUNDIR/boot.env'" "state file has SERVER_PID"
assert_true "grep -q '^BASE_URL=http://127.0.0.1:' '$RUNDIR/boot.env'" "state file has BASE_URL"
assert_true "[ -f '$MARKER' ] && grep -q '^_h_14$' '$MARKER'" "db_setup_commands saw the run-suffix env var"
SERVER_PID="$(grep '^SERVER_PID=' "$RUNDIR/boot.env" | cut -d= -f2)"
assert_true "pid_alive $SERVER_PID" "server process is actually running"
boot_stop "$PROJ" "$RUNDIR" H-14 >/dev/null 2>&1
sleep 0.3
assert_true "! pid_alive $SERVER_PID" "--stop killed the server"
assert_true "[ ! -f '$RUNDIR/boot.env' ]" "--stop removed the state file"
assert_true "[ ! -f '$RUNDIR/server.pid' ]" "--stop removed the pidfile too"
unset MOCK_DROPDB_LOG

# ---------------------------------------------------------------------------
# 2. State file quoting: a value containing shell metacharacters round-
#    trips through write_state() and a later `source` exactly, instead of
#    being interpreted. Exercises write_state()'s real body (extracted
#    from boot.sh) rather than a hand-copied guess at it, so a plain
#    printf '%s=%s' regression here would actually fail this check.
# ---------------------------------------------------------------------------
section "state file quoting neutralizes shell metacharacters"
TESTDIR="$(new_rundir)"
STATE_FILE="$TESTDIR/boot.env"
MARKER="$TESTDIR/pwned"
DANGEROUS="ok; touch $MARKER; echo done"
WRITE_STATE_BODY="$(sed -n '/^write_state() {/,/^}/p' "$BOOT_SH")"
assert_true "[ -n \"\$WRITE_STATE_BODY\" ]" "found write_state() in boot.sh to extract"
( eval "$WRITE_STATE_BODY"; write_state RUN_DB "$DANGEROUS" )
RUN_DB=""
# shellcheck disable=SC1090
source "$STATE_FILE"
assert_eq "$RUN_DB" "$DANGEROUS" "sourced value matches the original exactly, semicolons included"
assert_true "[ ! -e '$MARKER' ]" "no injected command ran while sourcing the state file"

# ---------------------------------------------------------------------------
# 3. --stop with nothing booted: exits 0, no error.
# ---------------------------------------------------------------------------
section "--stop: nothing to stop"
PROJ="$(new_project)"
RUNDIR="$(new_rundir)"
write_config "$PROJ" "$(server_cmd normal)" '[]' '["true"]' ""
boot_stop "$PROJ" "$RUNDIR" H-99 >/dev/null 2>&1
assert_eq "$?" "0" "--stop with no state file exits 0"

# ---------------------------------------------------------------------------
# 4. Missing required key: named, exit 1.
# ---------------------------------------------------------------------------
section "missing config key"
PROJ="$(new_project)"
RUNDIR="$(new_rundir)"
write_config "$PROJ" "$(server_cmd normal)" '[]' '["true"]' "db_credentials_command"
ERR="$(boot "$PROJ" "$RUNDIR" H-1 2>&1 1>/dev/null)"
RC=$?
assert_eq "$RC" "1" "exits 1"
assert_true "echo \"$ERR\" | grep -q 'db_credentials_command'" "names the missing key"
assert_true "[ ! -f '$RUNDIR/boot.env' ]" "no state file left behind"

# ---------------------------------------------------------------------------
# 5. Build failure: a failing build_commands entry aborts the boot, the
#    trap runs (this is a normal exit, not a SIGKILL), and no state file
#    or leftover run database is left for a later boot to trip over.
# ---------------------------------------------------------------------------
section "build failure"
PROJ="$(new_project)"
RUNDIR="$(new_rundir)"
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
unset MOCK_DROPDB_LOG

# ---------------------------------------------------------------------------
# 6. Server retry exhaustion: the server keeps crashing before it answers
#    healthy. All three attempts run, boot.sh exits 2, and cleanup drops
#    the run database it had already created.
# ---------------------------------------------------------------------------
section "server retry exhaustion"
PROJ="$(new_project)"
RUNDIR="$(new_rundir)"
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
unset MOCK_DROPDB_LOG

# ---------------------------------------------------------------------------
# 7. Retry-loop leak, fixed path: sh -c "$SERVER_CMD" backgrounds the
#    server, writes the pidfile, then the launcher itself exits non-zero.
#    The pidfile identifies the leaked listener, so it gets killed.
# ---------------------------------------------------------------------------
section "retry-loop leak: launcher exits non-zero after backgrounding"
PROJ="$(new_project)"
RUNDIR="$(new_rundir)"
export MOCK_DROPDB_LOG="$RUNDIR/dropdb.log"
: > "$MOCK_DROPDB_LOG"
write_config "$PROJ" "$(server_cmd write-pidfile-then-fail)" '[]' '["true"]' ""
boot "$PROJ" "$RUNDIR" H-4 >/dev/null 2>&1
RC=$?
assert_eq "$RC" "2" "exits 2 (every attempt takes this path)"
sleep 0.3
LEFTOVER="$(pgrep -f -- "--pidfile $RUNDIR/server.pid" || true)"
assert_eq "$LEFTOVER" "" "no fake-server listener process survives the run"
unset MOCK_DROPDB_LOG

# ---------------------------------------------------------------------------
# 8. Retry-loop leak, unfixable path: a launcher that never writes the
#    pidfile leaks whatever it forked, since nothing here can identify
#    it (no pid was ever recorded anywhere). This is a documented
#    limitation, not a bug -- this check confirms boot.sh still behaves
#    (and fails cleanly) rather than asserting the leak is gone.
#    UI_CAPTURE_PIDFILE_WAIT_TRIES shortens the wait so this is cheap to
#    run instead of costing 3x30s.
# ---------------------------------------------------------------------------
section "retry-loop, documented limitation: launcher never writes a pidfile"
PROJ="$(new_project)"
RUNDIR="$(new_rundir)"
export MOCK_DROPDB_LOG="$RUNDIR/dropdb.log"
: > "$MOCK_DROPDB_LOG"
write_config "$PROJ" "$(server_cmd never-pidfile)" '[]' '["true"]' ""
UI_CAPTURE_PIDFILE_WAIT_TRIES=4 boot "$PROJ" "$RUNDIR" H-8 >/dev/null 2>&1
RC=$?
assert_eq "$RC" "2" "exits 2 after exhausting retries -- never crashes or hangs"
assert_true "[ ! -f '$RUNDIR/boot.env' ]" "cleanup trap removed the state file (nothing else to recover)"
sleep 0.5
LEFTOVER="$(pgrep -f -- "--pidfile $RUNDIR/server.pid" || true)"
assert_true "[ -n '$LEFTOVER' ]" "the forked listener is left running -- the known, documented limitation, not a silent regression"
echo "$LEFTOVER" | xargs -r kill -9 2>/dev/null
unset MOCK_DROPDB_LOG

# ---------------------------------------------------------------------------
# 9. Retry-loop, total launch failure: the launcher itself exits non-zero
#    before backgrounding anything. Nothing to kill, nothing leaked.
# ---------------------------------------------------------------------------
section "retry-loop: launcher fails before backgrounding anything"
PROJ="$(new_project)"
RUNDIR="$(new_rundir)"
export MOCK_DROPDB_LOG="$RUNDIR/dropdb.log"
: > "$MOCK_DROPDB_LOG"
write_config "$PROJ" "$(server_cmd exit-nonzero-no-listener)" '[]' '["true"]' ""
boot "$PROJ" "$RUNDIR" H-9 >/dev/null 2>&1
assert_eq "$?" "2" "exits 2 (every attempt fails immediately)"
assert_true "[ ! -f '$RUNDIR/boot.env' ]" "cleanup trap removed the state file"
unset MOCK_DROPDB_LOG

# ---------------------------------------------------------------------------
# 10. usage errors: a flag given with no value falls through to usage
#     instead of crashing on `set -u`'s "unbound variable".
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
# 11. Ticket sanitization keeps distinct tickets distinct: the exact line
#     from boot.sh is extracted and exercised directly, so this tracks
#     the real implementation instead of a hand-copied guess at it.
# ---------------------------------------------------------------------------
section "ticket sanitization stays distinct"
SANITIZE_LINE="$(grep '^SANITIZED_TICKET=' "$BOOT_SH")"
sanitize() { TICKET="$1"; eval "$SANITIZE_LINE"; echo "$SANITIZED_TICKET"; }
A="$(sanitize 'H-14')"
B="$(sanitize 'H14')"
C="$(sanitize 'h.1.4')"
assert_true "[ '$A' != '$B' ] && [ '$A' != '$C' ] && [ '$B' != '$C' ]" "H-14 ($A), H14 ($B), h.1.4 ($C) sanitize to three different strings"

# ---------------------------------------------------------------------------
# 12. A run database name over PostgreSQL's 63-byte identifier limit is
#     refused outright, instead of PostgreSQL silently truncating it into
#     a name that could collide with a different ticket's database.
# ---------------------------------------------------------------------------
section "run database name over the 63-byte limit is refused"
PROJ="$(new_project)"
RUNDIR="$(new_rundir)"
export MOCK_DROPDB_LOG="$RUNDIR/dropdb.log"
: > "$MOCK_DROPDB_LOG"
MARKER="$RUNDIR/setup-ran"
write_config "$PROJ" "$(server_cmd normal)" '[]' "[\"touch '$MARKER'\"]" ""
LONG_NAME="$(printf 'x%.0s' $(seq 1 70))"
patch_config "$PROJ" '.boot.db_credentials_command = $v' "printf '${LONG_NAME}|testuser|testpass\n'"
ERR="$(boot "$PROJ" "$RUNDIR" H-1 2>&1 1>/dev/null)"
RC=$?
assert_eq "$RC" "1" "refuses rather than truncating silently"
assert_true "echo \"$ERR\" | grep -qi '63-byte'" "error names the 63-byte PostgreSQL limit"
assert_true "[ ! -f '$MARKER' ]" "never reached db_setup_commands with the over-long name"
assert_true "[ ! -f '$RUNDIR/boot.env' ]" "no state file left behind"
unset MOCK_DROPDB_LOG

# ---------------------------------------------------------------------------
# 13. db_credentials_command output with no trailing newline still
#     parses -- bash's `read` signals "no trailing newline" via its own
#     exit status even when it populated the variables correctly, which
#     used to be misread as a parse failure.
# ---------------------------------------------------------------------------
section "credentials without a trailing newline still parse"
PROJ="$(new_project)"
RUNDIR="$(new_rundir)"
export MOCK_DROPDB_LOG="$RUNDIR/dropdb.log"
: > "$MOCK_DROPDB_LOG"
write_config "$PROJ" "$(server_cmd normal)" '[]' '["true"]' ""
patch_config "$PROJ" '.boot.db_credentials_command = $v' "printf %s 'testdb|testuser|testpass'"
boot "$PROJ" "$RUNDIR" H-10 >/dev/null 2>&1
assert_eq "$?" "0" "boot still succeeds with no trailing newline on the credentials line"
boot_stop "$PROJ" "$RUNDIR" H-10 >/dev/null 2>&1
unset MOCK_DROPDB_LOG

# ---------------------------------------------------------------------------
# 14. Double-boot guard: a second boot for a ticket that already has a
#     state file refuses, and leaves the first run untouched.
# ---------------------------------------------------------------------------
section "double-boot guard"
PROJ="$(new_project)"
RUNDIR="$(new_rundir)"
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
unset MOCK_DROPDB_LOG

# ---------------------------------------------------------------------------
# 15. run.sh's own cleanup trap must not undo the double-boot guard: a
#     run.sh invocation whose boot step gets refused (because its --out
#     collides with an already-running boot) must not then reach for
#     --stop on that same directory and tear down the run it correctly
#     declined to disturb.
# ---------------------------------------------------------------------------
section "run.sh cleanup only tears down a boot it actually started"
PROJ="$(new_project)"
RUNDIR="$(new_rundir)"
export MOCK_DROPDB_LOG="$RUNDIR/dropdb.log"
: > "$MOCK_DROPDB_LOG"
write_config "$PROJ" "$(server_cmd normal)" '[]' '["true"]' ""
boot "$PROJ" "$RUNDIR" H-7 >/dev/null 2>&1
FIRST_PID="$(grep '^SERVER_PID=' "$RUNDIR/boot.env" | cut -d= -f2)"
TARGETS_FILE="$RUNDIR/targets.json"
printf '{"ticket":"H-7","targets":[]}' > "$TARGETS_FILE"
( cd "$PROJ" && "$RUN_SH" --ticket H-7 --targets "$TARGETS_FILE" --out "$RUNDIR" >/dev/null 2>&1 )
RC=$?
assert_true "[ '$RC' -ne 0 ]" "run.sh's own boot step is refused by the double-boot guard"
assert_true "pid_alive $FIRST_PID" "run.sh's cleanup did not touch the first run's still-alive server"
assert_true "[ -f '$RUNDIR/boot.env' ]" "run.sh's cleanup did not remove the first run's state file"
boot_stop "$PROJ" "$RUNDIR" H-7 >/dev/null 2>&1
unset MOCK_DROPDB_LOG

# ---------------------------------------------------------------------------
# 16. Incremental state file survives a SIGKILL: kill boot.sh itself
#     partway through -- after SERVER_PID is on disk but before the
#     health check (and the trap, which SIGKILL bypasses entirely) ever
#     runs -- and confirm --stop can still find and tear the run down.
# ---------------------------------------------------------------------------
section "state file survives a mid-boot SIGKILL"
PROJ="$(new_project)"
RUNDIR="$(new_rundir)"
export MOCK_DROPDB_LOG="$RUNDIR/dropdb.log"
: > "$MOCK_DROPDB_LOG"
write_config "$PROJ" "$(server_cmd slow-health --delay 6)" '[]' '["true"]' ""
boot_bg "$PROJ" "$RUNDIR" H-6
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
unset MOCK_DROPDB_LOG

# ---------------------------------------------------------------------------
echo ""
echo "== summary =="
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
