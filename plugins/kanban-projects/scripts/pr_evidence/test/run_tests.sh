#!/usr/bin/env bash
# Synthetic test suite for publish.sh. Runs it against a throwaway clone
# whose remote is a local bare repository, so no network is needed.
#
#   plugins/kanban-projects/scripts/pr_evidence/test/run_tests.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PUBLISH="$(dirname "$SCRIPT_DIR")/publish.sh"
PASS=0
FAIL=0
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

ok() { PASS=$((PASS + 1)); echo "  ok: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; }
check() { if eval "$2"; then ok "$1"; else fail "$1"; fi; }

export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com

new_clone() {
  local name="$1"
  git clone --quiet "$TMP/remote.git" "$TMP/$name" 2>/dev/null
  git -C "$TMP/$name" checkout --quiet -b ticket/c-1 origin/main
}

write_capture() {
  local dir="$1"
  mkdir -p "$dir"
  printf 'png-sheet' > "$dir/contact-sheet-desktop.png"
  printf 'png-target' > "$dir/target-mobile.png"
  printf 'png-folded' > "$dir/folded.png"
  jq -n --arg d "$dir" '{ticket: "C-1", exit_code: 0, targets: [
    {name: "contact-sheet", kind: "still", viewport: "desktop", file: "\($d)/contact-sheet-desktop.png", status: 200, attach: true},
    {name: "players-index", kind: "still", viewport: "mobile", file: "target-mobile.png", status: 500, attach: true},
    {name: "folded", kind: "still", viewport: "desktop", file: "\($d)/folded.png", status: 200, attach: false},
    {name: "broken", kind: "still", viewport: "desktop", file: null, status: null, attach: true}
  ]}' > "$dir/result.json"
}

git init --quiet --bare "$TMP/remote.git"
git clone --quiet "$TMP/remote.git" "$TMP/seed" 2>/dev/null
git -C "$TMP/seed" checkout --quiet -b main
echo app > "$TMP/seed/app.txt"
git -C "$TMP/seed" add app.txt
git -C "$TMP/seed" commit --quiet -m init
git -C "$TMP/seed" push --quiet origin main

echo "== first round creates the branch =="
new_clone a
write_capture "$TMP/a/tmp/ui-capture/C-1"
(cd "$TMP/a" && "$PUBLISH" --ticket C-1 --result tmp/ui-capture/C-1/result.json --pr 7 >/dev/null)
check "exits 0" '[ $? -eq 0 ]'
check "evidence branch exists on the remote" 'git -C "$TMP/remote.git" rev-parse --verify --quiet evidence >/dev/null'
check "round is 1" '[ "$(jq .round "$TMP/a/tmp/ui-capture/C-1/evidence.json")" = 1 ]'
check "only attach:true entries with a file are published" '[ "$(jq ".files | length" "$TMP/a/tmp/ui-capture/C-1/evidence.json")" = 2 ]'
check "files land under <ticket>/r<round>/" '[ "$(git -C "$TMP/remote.git" ls-tree -r --name-only evidence | grep -c "^C-1/r1/")" = 2 ]'
check "evidence branch shares no history with main" '! git -C "$TMP/remote.git" merge-base main evidence >/dev/null 2>&1'
check "ticket checkout is untouched" '[ "$(git -C "$TMP/a" rev-parse --abbrev-ref HEAD)" = ticket/c-1 ] && [ -z "$(git -C "$TMP/a" status --porcelain -- app.txt)" ]'
check "URLs are pinned to the commit" 'grep -q "/blob/$(jq -r .commit "$TMP/a/tmp/ui-capture/C-1/evidence.json")/C-1/r1/" "$TMP/a/tmp/ui-capture/C-1/evidence.md"'
check "a non-200 status shows in the summary" 'grep -q "status 500" "$TMP/a/tmp/ui-capture/C-1/evidence.md"'
check "no worktree left behind" '[ "$(git -C "$TMP/a" worktree list | wc -l)" = 1 ]'

echo "== second round from another clone appends =="
new_clone b
write_capture "$TMP/b/tmp/ui-capture/C-1"
(cd "$TMP/b" && "$PUBLISH" --ticket C-1 --result tmp/ui-capture/C-1/result.json >/dev/null)
check "round is 2" '[ "$(jq .round "$TMP/b/tmp/ui-capture/C-1/evidence.json")" = 2 ]'
check "round 1 files are kept" '[ "$(git -C "$TMP/remote.git" ls-tree -r --name-only evidence | grep -c "^C-1/")" = 4 ]'

echo "== another ticket keeps the first ticket's files =="
write_capture "$TMP/a/tmp/ui-capture/C-2"
(cd "$TMP/a" && "$PUBLISH" --ticket C-2 --result tmp/ui-capture/C-2/result.json >/dev/null)
check "C-1 files survive a C-2 publish" '[ "$(git -C "$TMP/remote.git" ls-tree -r --name-only evidence | grep -c "^C-1/")" = 4 ]'
check "C-2 starts at round 1" '[ "$(jq .round "$TMP/a/tmp/ui-capture/C-2/evidence.json")" = 1 ]'

echo "== usage errors =="
(cd "$TMP/a" && "$PUBLISH" --ticket "../x" --result tmp/ui-capture/C-1/result.json >/dev/null 2>&1)
check "a ticket id with a slash is refused" '[ $? -eq 1 ]'

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
