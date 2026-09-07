#!/usr/bin/env bash
# Generic boot harness for a UI-capture run: builds the app, seeds a fresh
# run database, starts the server, and waits for it to answer. Run with
# --stop to tear the same run down again.
#
# Usage:
#   boot.sh --ticket <id> [--dir <path>] [--stop]
#
# This script ships with the kanban-automation plugin and knows nothing
# about any one project. It reads seven values from the project's
# .claude/ui-capture.json, under the "boot" key -- see README.md for the
# shape. A project whose boot procedure does not fit this shape points
# boot_command at its own script instead; this harness only runs when a
# project's boot_command names this file.
#
# --dir sets where this script keeps its own state and logs. Pass the SAME
# --dir run.sh uses as its --out, so both agree on one directory to erase
# afterward; without it, this picks tmp/ui-capture/<sanitized ticket>, for
# standalone use.
#
# On success (start mode) this prints two lines to stdout:
#   BASE_URL=http://127.0.0.1:<port>
#   <run_suffix_env_var>=_<sanitized ticket>
# A caller that queries the database directly must set that second
# variable to that value first, or it queries the shared, unseeded
# database instead of this run's own.
set -uo pipefail

usage() {
  echo "Usage: $0 --ticket <id> [--dir <path>] [--stop]" >&2
  exit 1
}

TICKET=""
STOP=false
DIR_OVERRIDE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --ticket) TICKET="$2"; shift 2 ;;
    --dir) DIR_OVERRIDE="$2"; shift 2 ;;
    --stop) STOP=true; shift ;;
    *) usage ;;
  esac
done
[ -n "$TICKET" ] || usage

log() { echo "[boot.sh] $*" >&2; }

# The working directory decides which project this boots, the same way
# run.sh decides which project it captures -- NOT $CLAUDE_PLUGIN_ROOT,
# which points at the plugin, not the project.
PROJECT_DIR="$(git rev-parse --show-toplevel 2>/dev/null)" || PROJECT_DIR="$(pwd)"
cd "$PROJECT_DIR" || exit 1

# ---------------------------------------------------------------------------
# The project's half of the contract: .claude/ui-capture.json's "boot" key.
# ---------------------------------------------------------------------------
CONFIG_FILE="$PROJECT_DIR/.claude/ui-capture.json"
if [ ! -f "$CONFIG_FILE" ]; then
  log "no $CONFIG_FILE -- this project has not been wired for UI capture yet"
  exit 1
fi
if ! jq empty "$CONFIG_FILE" 2>/dev/null; then
  log "$CONFIG_FILE is not valid JSON"
  exit 1
fi

read_config() { jq -r "$1 // empty" "$CONFIG_FILE"; }
read_config_array() { jq -r "($1 // [])[]" "$CONFIG_FILE"; }

DB_CREDENTIALS_COMMAND="$(read_config '.boot.db_credentials_command')"
SERVER_COMMAND="$(read_config '.boot.server_command')"
HEALTH_PATH="$(read_config '.boot.health_path')"
RUN_SUFFIX_VAR="$(read_config '.boot.run_suffix_env_var')"
mapfile -t BUILD_COMMANDS < <(read_config_array '.boot.build_commands')
mapfile -t DB_SETUP_COMMANDS < <(read_config_array '.boot.db_setup_commands')
mapfile -t HYDRATE_FILES < <(read_config_array '.boot.hydrate_files')

MISSING=""
[ -n "$DB_CREDENTIALS_COMMAND" ] || MISSING="$MISSING boot.db_credentials_command"
[ -n "$SERVER_COMMAND" ] || MISSING="$MISSING boot.server_command"
[ -n "$HEALTH_PATH" ] || MISSING="$MISSING boot.health_path"
[ -n "$RUN_SUFFIX_VAR" ] || MISSING="$MISSING boot.run_suffix_env_var"
[ "${#DB_SETUP_COMMANDS[@]}" -gt 0 ] || MISSING="$MISSING boot.db_setup_commands"
if [ -n "$MISSING" ]; then
  log "$CONFIG_FILE is missing:$MISSING"
  exit 1
fi
if [[ ! "$RUN_SUFFIX_VAR" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
  log "boot.run_suffix_env_var '$RUN_SUFFIX_VAR' is not a valid environment variable name"
  exit 1
fi

# A dispatch worktree has neither node_modules nor its own copy of files
# .gitignore keeps out of the tree; both come from the main checkout when
# this worktree doesn't already have them. From inside any worktree, git's
# common dir is the main checkout's .git, so its parent is the main
# checkout.
default_main_checkout() {
  local common_dir
  common_dir="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || return 1
  [ -n "$common_dir" ] || return 1
  dirname "$common_dir"
}
MAIN_CHECKOUT="${UI_CAPTURE_MAIN_CHECKOUT:-$(default_main_checkout || echo "$PROJECT_DIR")}"

SANITIZED_TICKET="$(echo "$TICKET" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9')"
[ -n "$SANITIZED_TICKET" ] || { log "ticket '$TICKET' sanitizes to an empty run-db name"; exit 1; }
RUN_SUFFIX="_${SANITIZED_TICKET}"

RUN_DIR="${DIR_OVERRIDE:-$PROJECT_DIR/tmp/ui-capture/$SANITIZED_TICKET}"
STATE_FILE="$RUN_DIR/boot.env"
mkdir -p "$RUN_DIR"

# ---------------------------------------------------------------------------
# Database credentials, read fresh whenever needed -- never written to disk.
# ---------------------------------------------------------------------------
fetch_credentials() {
  local err
  err="$(mktemp)"
  if ! IFS='|' read -r DB_NAME DB_USERNAME DB_PASSWORD < <(sh -c "$DB_CREDENTIALS_COMMAND" 2>"$err") \
    || [ -z "$DB_NAME" ]; then
    log "could not read database credentials:"
    cat "$err" >&2
    rm -f "$err"
    return 1
  fi
  rm -f "$err"
}

# ---------------------------------------------------------------------------
# --stop
# ---------------------------------------------------------------------------
stop() {
  if [ ! -f "$STATE_FILE" ]; then
    log "no boot state for ticket '$TICKET' ($STATE_FILE missing) -- nothing to stop"
    return 0
  fi
  # shellcheck disable=SC1090
  source "$STATE_FILE"

  if [ -n "${SERVER_PID:-}" ] && kill -0 "$SERVER_PID" 2>/dev/null; then
    log "stopping server (pid $SERVER_PID)"
    kill "$SERVER_PID" 2>/dev/null || true
    for _ in $(seq 1 20); do
      kill -0 "$SERVER_PID" 2>/dev/null || break
      sleep 0.5
    done
    kill -9 "$SERVER_PID" 2>/dev/null || true
  fi

  if [ -n "${RUN_DB:-}" ]; then
    if fetch_credentials; then
      log "dropping run database $RUN_DB"
      PGPASSWORD="$DB_PASSWORD" dropdb -h 127.0.0.1 -U "$DB_USERNAME" --if-exists "$RUN_DB" 2>/dev/null || true
    else
      log "could not re-read credentials to drop $RUN_DB -- drop it by hand"
    fi
  fi

  rm -f "$STATE_FILE"
}

if [ "$STOP" = true ]; then
  stop
  exit 0
fi

# ---------------------------------------------------------------------------
# Failure trap -- from here on, any non-zero exit drops the run database and
# kills the server, even though the state file (which --stop normally reads)
# isn't written until the very end of a successful boot.
# ---------------------------------------------------------------------------
RUN_DB=""
SERVER_PID=""
CLEANED_UP=false
cleanup_on_failure() {
  local rc=$?
  [ "$rc" -eq 0 ] && return
  [ "$CLEANED_UP" = true ] && return
  CLEANED_UP=true
  log "boot failed (exit $rc) -- cleaning up"
  if [ -n "$SERVER_PID" ] && kill -0 "$SERVER_PID" 2>/dev/null; then
    kill "$SERVER_PID" 2>/dev/null || true
  fi
  if [ -n "$RUN_DB" ] && [ -n "${DB_USERNAME:-}" ]; then
    PGPASSWORD="${DB_PASSWORD:-}" dropdb -h 127.0.0.1 -U "$DB_USERNAME" --if-exists "$RUN_DB" 2>/dev/null || true
  fi
}
trap cleanup_on_failure EXIT

set -e

# One log for every build/install command this run makes, truncated here so
# a run reusing the same --dir never appends onto an earlier run's log.
: > "$RUN_DIR/build.log"

# ---------------------------------------------------------------------------
# Hydrate the worktree: node_modules unconditionally; anything else the
# project names in boot.hydrate_files.
# ---------------------------------------------------------------------------
if [ ! -e "$PROJECT_DIR/node_modules" ]; then
  if [ -d "$MAIN_CHECKOUT/node_modules" ]; then
    log "symlinking node_modules from $MAIN_CHECKOUT"
    ln -s "$MAIN_CHECKOUT/node_modules" "$PROJECT_DIR/node_modules"
  else
    log "installing node_modules (no main checkout to symlink from)"
    npm install >>"$RUN_DIR/build.log" 2>&1
  fi
fi
for rel in "${HYDRATE_FILES[@]}"; do
  [ -n "$rel" ] || continue
  if [ ! -e "$PROJECT_DIR/$rel" ] && [ -e "$MAIN_CHECKOUT/$rel" ]; then
    log "copying $rel from $MAIN_CHECKOUT"
    mkdir -p "$(dirname "$PROJECT_DIR/$rel")"
    cp -r "$MAIN_CHECKOUT/$rel" "$PROJECT_DIR/$rel"
  fi
done

# ---------------------------------------------------------------------------
# Build.
# ---------------------------------------------------------------------------
for cmd in "${BUILD_COMMANDS[@]}"; do
  [ -n "$cmd" ] || continue
  log "building: $cmd"
  sh -c "$cmd" >>"$RUN_DIR/build.log" 2>&1
done

fetch_credentials || exit 2

# ---------------------------------------------------------------------------
# Drop and recreate a per-run database named by a suffix.
# ---------------------------------------------------------------------------
RUN_DB="${DB_NAME}${RUN_SUFFIX}"
PGPASSWORD="$DB_PASSWORD" dropdb -h 127.0.0.1 -U "$DB_USERNAME" --if-exists "$RUN_DB"
log "setting up $RUN_DB"
for cmd in "${DB_SETUP_COMMANDS[@]}"; do
  [ -n "$cmd" ] || continue
  env "$RUN_SUFFIX_VAR=$RUN_SUFFIX" sh -c "$cmd"
done

# ---------------------------------------------------------------------------
# Free port + server start, retried in case a concurrent dispatch takes the
# port between the bind-and-close check and the server actually binding it.
# ---------------------------------------------------------------------------
free_port() {
  node -e '
    const net = require("net");
    const srv = net.createServer();
    srv.listen(0, "127.0.0.1", () => {
      const port = srv.address().port;
      srv.close(() => console.log(port));
    });
  '
}

PIDFILE="$RUN_DIR/server.pid"
BASE_URL=""
START_ATTEMPTS=3
for attempt in $(seq 1 "$START_ATTEMPTS"); do
  PORT="$(free_port)"
  rm -f "$PIDFILE"

  SERVER_CMD="${SERVER_COMMAND//\{port\}/$PORT}"
  SERVER_CMD="${SERVER_CMD//\{pidfile\}/$PIDFILE}"

  log "starting server on port $PORT against $RUN_DB (attempt $attempt/$START_ATTEMPTS)"
  if ! env "$RUN_SUFFIX_VAR=$RUN_SUFFIX" sh -c "$SERVER_CMD" >"$RUN_DIR/server-boot.log" 2>&1; then
    log "server failed to start on port $PORT, retrying"
    continue
  fi

  CANDIDATE_URL="http://127.0.0.1:${PORT}"
  for _ in $(seq 1 60); do
    [ -f "$PIDFILE" ] && break
    sleep 0.5
  done
  if [ ! -f "$PIDFILE" ]; then
    log "server never wrote a pidfile on port $PORT, retrying"
    continue
  fi
  SERVER_PID="$(cat "$PIDFILE")"

  READY=false
  for _ in $(seq 1 60); do
    if curl -fsS -o /dev/null -w '%{http_code}' "$CANDIDATE_URL$HEALTH_PATH" 2>/dev/null | grep -q '^200$'; then
      READY=true
      break
    fi
    kill -0 "$SERVER_PID" 2>/dev/null || break
    sleep 0.5
  done

  if [ "$READY" = true ]; then
    BASE_URL="$CANDIDATE_URL"
    break
  fi

  log "server on port $PORT never answered $HEALTH_PATH, retrying"
  kill "$SERVER_PID" 2>/dev/null || true
  SERVER_PID=""
done

[ -n "$BASE_URL" ] || { log "could not start server after $START_ATTEMPTS attempts"; exit 2; }

cat > "$STATE_FILE" <<EOF
SERVER_PID=$SERVER_PID
RUN_DB=$RUN_DB
BASE_URL=$BASE_URL
EOF

log "ready: $BASE_URL (db $RUN_DB, pid $SERVER_PID)"
echo "BASE_URL=$BASE_URL"
echo "$RUN_SUFFIX_VAR=$RUN_SUFFIX"
