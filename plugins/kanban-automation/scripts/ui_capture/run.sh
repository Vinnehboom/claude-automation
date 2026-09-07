#!/usr/bin/env bash
# One command for a UI-capture run: boots the app, merges the core surface
# with the ticket's Capture plan, runs capture.mjs, builds result.json, and
# always tears the server and run database down again.
#
# Usage:
#   run.sh --ticket <id> --targets <path> --out <dir> [--budget <seconds>]
#          [--project-dir <path>]
#
# This script ships with the kanban-automation plugin and knows nothing about
# any one project. It reads .claude/ui-capture.json from the project for the
# three things it cannot know: how to boot the app, how to list the app's own
# page-rendering routes, and how to sign in. See README.md for that file's
# shape.
#
# --targets points at the ticket's own Capture plan (the JSON the orchestrator
# writes to tmp/ui-capture/<TASK_ID>.json). run.sh adds the core surface
# itself, from the project's core_targets_command. Always run this from the
# ticket branch's own checkout -- it resolves the core surface and captures
# whatever code is checked out right here, not necessarily the branch named
# in --ticket.
#
# Exit codes: 0 success, 1 usage or configuration error, 2 boot failure,
# 3 capture failure, 4 budget expired. A capture FAILURE (this script's own
# exit code) never blocks a PR by itself -- that is a decision the Gatekeeper
# makes by reading result.json's per-target status, not by reading this exit
# code.
set -uo pipefail

usage() {
  echo "Usage: $0 --ticket <id> --targets <path> --out <dir> [--budget <seconds>] [--project-dir <path>]" >&2
  exit 1
}

TICKET=""
TARGETS_FILE=""
OUT_DIR=""
BUDGET=600
PROJECT_DIR=""
while [ $# -gt 0 ]; do
  case "$1" in
    --ticket) [ $# -ge 2 ] || usage; TICKET="$2"; shift 2 ;;
    --targets) [ $# -ge 2 ] || usage; TARGETS_FILE="$2"; shift 2 ;;
    --out) [ $# -ge 2 ] || usage; OUT_DIR="$2"; shift 2 ;;
    --budget) [ $# -ge 2 ] || usage; BUDGET="$2"; shift 2 ;;
    --project-dir) [ $# -ge 2 ] || usage; PROJECT_DIR="$2"; shift 2 ;;
    *) usage ;;
  esac
done
[ -n "$TICKET" ] && [ -n "$TARGETS_FILE" ] && [ -n "$OUT_DIR" ] || usage
[ -f "$TARGETS_FILE" ] || { echo "targets file not found: $TARGETS_FILE" >&2; exit 1; }

# A non-numeric or non-positive --budget would otherwise become 0 in the
# arithmetic below and corrupt result.json's budget_seconds field.
case "$BUDGET" in
  ''|*[!0-9]*) echo "[run.sh] invalid --budget '$BUDGET', defaulting to 600" >&2; BUDGET=600 ;;
esac
[ "$BUDGET" -gt 0 ] || { echo "[run.sh] --budget must be positive, defaulting to 600" >&2; BUDGET=600; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CAPTURE_MJS="$SCRIPT_DIR/capture.mjs"

# boot_command runs inside the fresh `sh -c` below, not inside this shell,
# so a project that writes ${CLAUDE_PLUGIN_ROOT} into boot_command needs
# that variable in THAT child's environment, not just in this one.
export CLAUDE_PLUGIN_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"

# The working directory decides which checkout gets captured, so it is the
# default -- NOT $CLAUDE_PROJECT_DIR, which points at the session's own main
# checkout and would silently capture the wrong branch from a dispatch
# worktree.
if [ -z "$PROJECT_DIR" ]; then
  PROJECT_DIR="$(git rev-parse --show-toplevel 2>/dev/null)" || {
    echo "[run.sh] not inside a git checkout and no --project-dir given" >&2
    exit 1
  }
fi
cd "$PROJECT_DIR" || exit 1

log() { echo "[run.sh] $*" >&2; }

# ---------------------------------------------------------------------------
# The project's half of the contract.
# ---------------------------------------------------------------------------
CONFIG_FILE="$PROJECT_DIR/.claude/ui-capture.json"
if [ ! -f "$CONFIG_FILE" ]; then
  log "no $CONFIG_FILE -- this project has not been wired for UI capture yet"
  log "see the kanban-automation plugin's scripts/ui_capture/README.md for its shape"
  exit 1
fi
if ! jq empty "$CONFIG_FILE" 2>/dev/null; then
  log "$CONFIG_FILE is not valid JSON"
  exit 1
fi

read_config() { jq -r "$1 // empty" "$CONFIG_FILE"; }
BOOT_COMMAND="$(read_config '.boot_command')"
CORE_TARGETS_COMMAND="$(read_config '.core_targets_command')"

MISSING=""
[ -n "$BOOT_COMMAND" ] || MISSING="$MISSING boot_command"
[ -n "$CORE_TARGETS_COMMAND" ] || MISSING="$MISSING core_targets_command"
if [ -n "$MISSING" ]; then
  log "$CONFIG_FILE is missing:$MISSING"
  exit 1
fi

mkdir -p "$OUT_DIR"
OUT_DIR="$(cd "$OUT_DIR" && pwd)"
START_TIME=$(date +%s)

write_result() {
  local code="$1" message="$2" manifest="[]" elapsed
  [ -f "$OUT_DIR/manifest.json" ] && manifest="$(cat "$OUT_DIR/manifest.json")"
  elapsed=$(( $(date +%s) - START_TIME ))
  jq -n --arg ticket "$TICKET" --argjson code "$code" --argjson budget "$BUDGET" \
        --argjson elapsed "$elapsed" --arg message "$message" --argjson targets "$manifest" '
    { ticket: $ticket, exit_code: $code, budget_seconds: $budget, elapsed_seconds: $elapsed,
      message: $message, targets: $targets }
  ' > "$OUT_DIR/result.json"
}

CLEANED_UP=false
cleanup() {
  [ "$CLEANED_UP" = true ] && return
  CLEANED_UP=true
  log "tearing down"
  sh -c "$BOOT_COMMAND --ticket \"\$1\" --dir \"\$2\" --stop" sh "$TICKET" "$OUT_DIR" >/dev/null 2>&1 || true
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

# ---------------------------------------------------------------------------
# Boot. The project's boot_command prints KEY=value lines on stdout; BASE_URL
# is required and every other line is exported for the commands that follow,
# so a project can hand its core_targets_command whatever environment its own
# boot established (a run-database suffix, a port, a token).
# ---------------------------------------------------------------------------
BOOT_OUTPUT="$(mktemp)"
if ! sh -c "$BOOT_COMMAND --ticket \"\$1\" --dir \"\$2\"" sh "$TICKET" "$OUT_DIR" >"$BOOT_OUTPUT" 2>&1; then
  log "boot failed"
  cat "$BOOT_OUTPUT" >&2
  rm -f "$BOOT_OUTPUT"
  write_result 2 "boot failure"
  exit 2
fi

BASE_URL=""
while IFS= read -r line; do
  case "$line" in
    [A-Za-z_]*=*)
      key="${line%%=*}"
      value="${line#*=}"
      case "$key" in
        BASE_URL) BASE_URL="$value" ;;
        *) export "$key=$value" ;;
      esac
      ;;
  esac
done < "$BOOT_OUTPUT"
cat "$BOOT_OUTPUT" >&2
rm -f "$BOOT_OUTPUT"

[ -n "$BASE_URL" ] || { log "boot printed no BASE_URL line"; write_result 2 "boot produced no base URL"; exit 2; }
log "booted at $BASE_URL"

# ---------------------------------------------------------------------------
# Merge the core surface with the ticket's Capture plan.
# A ticket target whose path matches a core target replaces it.
# ---------------------------------------------------------------------------
CORE_JSON="$(mktemp)"
CORE_ERR="$(mktemp)"
if ! sh -c "$CORE_TARGETS_COMMAND" >"$CORE_JSON" 2>"$CORE_ERR"; then
  log "could not resolve the core capture surface"
  cat "$CORE_ERR" >&2
  rm -f "$CORE_JSON" "$CORE_ERR"
  write_result 2 "core target resolution failed"
  exit 2
fi
cat "$CORE_ERR" >&2
rm -f "$CORE_ERR"

if ! jq -e 'type == "array"' "$CORE_JSON" >/dev/null 2>&1; then
  log "core_targets_command did not print a JSON array"
  rm -f "$CORE_JSON"
  write_result 2 "core target resolution printed no JSON array"
  exit 2
fi

TICKET_JSON="$(mktemp)"
if ! jq '.targets // []' "$TARGETS_FILE" > "$TICKET_JSON" 2>/dev/null; then
  log "targets file is not valid JSON: $TARGETS_FILE"
  write_result 1 "invalid targets file"
  exit 1
fi

MERGED_JSON="$OUT_DIR/merged-targets.json"
if ! jq -n --slurpfile core "$CORE_JSON" --slurpfile ticket "$TICKET_JSON" '
  ($core[0] | map(. + {source: "core"})) as $core_tagged |
  ($ticket[0]) as $ticket_targets |
  ($ticket_targets | map(.path)) as $ticket_paths |
  {
    targets: (
      ($core_tagged | map(select(.path as $p | ($ticket_paths | index($p)) | not)))
      + $ticket_targets
    )
  }
' > "$MERGED_JSON" 2>/dev/null; then
  log "could not merge core and ticket targets"
  write_result 1 "target merge failed"
  exit 1
fi
rm -f "$CORE_JSON" "$TICKET_JSON"

# ---------------------------------------------------------------------------
# Capture, bounded by whatever is left of the budget.
# ---------------------------------------------------------------------------
ELAPSED=$(( $(date +%s) - START_TIME ))
REMAINING=$(( BUDGET - ELAPSED ))
if [ "$REMAINING" -le 0 ]; then
  log "budget already spent before capture started"
  write_result 4 "budget expired before capture started"
  exit 4
fi

log "capturing (budget ${REMAINING}s remaining)"
CAPTURE_LOG="$OUT_DIR/capture.log"
NODE_PATH_GLOBAL="$(npm root -g)"
# -k gives node a grace period to close Chromium cleanly after SIGTERM,
# then SIGKILLs the whole thing if that didn't finish in time.
NODE_PATH="$NODE_PATH_GLOBAL" timeout -k 10s "${REMAINING}s" node "$CAPTURE_MJS" \
  --targets "$MERGED_JSON" --out "$OUT_DIR" --base-url "$BASE_URL" \
  --config "$CONFIG_FILE" --project-dir "$PROJECT_DIR" \
  >"$CAPTURE_LOG" 2>&1
CAPTURE_RC=$?
cat "$CAPTURE_LOG" >&2

if [ "$CAPTURE_RC" -eq 124 ]; then
  log "capture exceeded its budget"
  write_result 4 "budget expired during capture"
  exit 4
elif [ "$CAPTURE_RC" -ne 0 ]; then
  log "capture failed (exit $CAPTURE_RC)"
  write_result 3 "capture failure"
  exit 3
fi

write_result 0 "ok"
log "done"
exit 0
