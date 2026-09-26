#!/usr/bin/env bash
# Commits one Gatekeeper round's capture files to the repository's evidence
# branch and writes the Markdown that embeds them in a pull request body.
#
#   publish.sh --ticket <TASK_ID> --result <dir>/result.json [--pr <number>]
#              [--branch evidence] [--remote origin]
#
# Run it from the ticket branch's checkout. It never touches that checkout:
# the evidence branch is built in a separate worktree and pushed from there.
#
# Output, in the result.json's own directory:
#   evidence.json  {round, commit, branch, files: [{name, viewport, kind, status, path, url}]}
#   evidence.md    the Markdown for the PR body's "Testing evidence" section
#
# Exit codes: 0 published (or nothing to publish), 1 usage error,
# 2 a git step failed (the push included, after its retries).
set -euo pipefail

TICKET="" RESULT="" PR="" BRANCH="evidence" REMOTE="origin"
while [ $# -gt 0 ]; do
  case "$1" in
    --ticket) TICKET="$2"; shift 2 ;;
    --result) RESULT="$2"; shift 2 ;;
    --pr) PR="$2"; shift 2 ;;
    --branch) BRANCH="$2"; shift 2 ;;
    --remote) REMOTE="$2"; shift 2 ;;
    *) echo "publish.sh: unknown argument $1" >&2; exit 1 ;;
  esac
done
[ -n "$TICKET" ] && [ -f "$RESULT" ] || { echo "publish.sh: --ticket and an existing --result are required" >&2; exit 1; }
case "$TICKET" in *[!A-Za-z0-9-]*) echo "publish.sh: ticket id must be letters, digits and dashes" >&2; exit 1 ;; esac

RESULT_DIR="$(cd "$(dirname "$RESULT")" && pwd)"
RESULT="$RESULT_DIR/$(basename "$RESULT")"
REPO_ROOT="$(git rev-parse --show-toplevel)"
WORKTREE="$(mktemp -d)"
cleanup() { git -C "$REPO_ROOT" worktree remove --force "$WORKTREE" >/dev/null 2>&1 || rm -rf "$WORKTREE"; }
trap cleanup EXIT

SLUG="$(git -C "$REPO_ROOT" remote get-url "$REMOTE" | sed -E 's#(\.git)?/?$##; s#^.*github\.com[:/]##')"

FILES="$(jq -c '[.targets[] | select(.attach == true and .file != null)]' "$RESULT")"
if [ "$(jq 'length' <<<"$FILES")" -eq 0 ]; then
  jq -n --arg branch "$BRANCH" '{round: null, commit: null, branch: $branch, files: []}' > "$RESULT_DIR/evidence.json"
  echo "No capture files to publish." > "$RESULT_DIR/evidence.md"
  exit 0
fi

git_or_fail() { git -C "$WORKTREE" "$@" || { echo "publish.sh: git $1 failed" >&2; exit 2; }; }

prepare_worktree() {
  rm -rf "$WORKTREE"
  git -C "$REPO_ROOT" worktree prune
  if git -C "$REPO_ROOT" fetch --quiet "$REMOTE" "$BRANCH" 2>/dev/null; then
    git -C "$REPO_ROOT" worktree add --quiet --detach "$WORKTREE" FETCH_HEAD
  else
    git -C "$REPO_ROOT" worktree add --quiet --detach "$WORKTREE"
    git_or_fail checkout --quiet --orphan "evidence-tmp-$$"
    git_or_fail rm -rf --quiet . >/dev/null
    printf '# Evidence\n\nScreenshots and recordings that ticket PRs embed. Nothing here merges into the default branch.\n' > "$WORKTREE/README.md"
    git_or_fail add README.md
    git_or_fail commit --quiet -m "Start the evidence branch"
  fi
}

next_round() {
  local highest
  highest="$(find "$WORKTREE/$TICKET" -maxdepth 1 -type d -name 'r[0-9]*' 2>/dev/null \
    | sed -E 's#.*/r([0-9]+)$#\1#' | sort -n | tail -1)"
  echo $(( ${highest:-0} + 1 ))
}

copy_round() {
  local round="$1" dir="$TICKET/r$1"
  mkdir -p "$WORKTREE/$dir"
  jq -c '.[]' <<<"$FILES" | while read -r entry; do
    local src name viewport ext dest
    src="$(jq -r '.file' <<<"$entry")"
    case "$src" in /*) ;; *) src="$RESULT_DIR/$src" ;; esac
    name="$(jq -r '.name' <<<"$entry")"
    viewport="$(jq -r '.viewport // "any"' <<<"$entry")"
    ext="${src##*.}"
    dest="$dir/$name-$viewport.$ext"
    cp "$src" "$WORKTREE/$dest"
    jq -c --arg path "$dest" '{name, viewport, kind, status, path: $path}' <<<"$entry"
  done > "$RESULT_DIR/.round-files"
  git_or_fail add "$dir"
  git_or_fail commit --quiet -m "$TICKET round $round evidence${PR:+ for #$PR}"
}

# Another ticket thread can push to the same branch between our fetch and
# our push. Rebuild the round on the new tip and try again; never force.
ROUND="" PUSHED=""
for attempt in 1 2 3 4; do
  prepare_worktree
  ROUND="$(next_round)"
  copy_round "$ROUND"
  if git -C "$WORKTREE" push --quiet "$REMOTE" "HEAD:refs/heads/$BRANCH"; then PUSHED=1; break; fi
  sleep $(( 2 ** attempt ))
done
[ -n "$PUSHED" ] || { echo "publish.sh: push to $BRANCH failed after 4 attempts" >&2; exit 2; }

COMMIT="$(git -C "$WORKTREE" rev-parse HEAD)"
BASE="https://github.com/$SLUG/blob/$COMMIT"

jq -s --argjson round "$ROUND" --arg commit "$COMMIT" --arg branch "$BRANCH" --arg base "$BASE" '
  {round: $round, commit: $commit, branch: $branch,
   files: map(. + {url: "\($base)/\(.path)?raw=true"})}
' "$RESULT_DIR/.round-files" > "$RESULT_DIR/evidence.json"

jq -r --arg ticket "$TICKET" '
  "Round \(.round) of the UI capture for \($ticket), from commit `\(.commit[0:7])` of the `\(.branch)` branch.\n",
  (.files[] |
    if .kind == "video" then
      "- [\(.name) (\(.viewport), video)](\(.url | sub("\\?raw=true$"; "")))"
    else
      "<details><summary>\(.name) (\(.viewport))\(if .status != null and .status != 200 then ", status \(.status)" else "" end)</summary>\n\n![\(.name) \(.viewport)](\(.url))\n\n</details>"
    end)
' "$RESULT_DIR/evidence.json" > "$RESULT_DIR/evidence.md"

rm -f "$RESULT_DIR/.round-files"
echo "Published round $ROUND of $TICKET to $BRANCH at $COMMIT"
