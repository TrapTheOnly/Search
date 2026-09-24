#!/bin/bash
# Tracks how far this fork (TrapTheOnly/Search) is behind upstream
# (driceroland/Search): commits, tags/releases, and a triage-friendly report.
#
#   ./upstream-sync.sh                 summary on stdout
#   ./upstream-sync.sh --fetch         git fetch upstream --tags first
#   ./upstream-sync.sh --report PATH   write a markdown report to PATH
#   ./upstream-sync.sh --help
#
# Defaults: local HEAD (or --base REF) vs upstream/main (or --upstream REF).
# Does not merge, cherry-pick, or change the working tree other than writing
# the report path you pass.
set -euo pipefail

cd "$(dirname "$0")"

FETCH=0
REPORT=""
BASE_REF="HEAD"
UP_REF="upstream/main"
UP_REMOTE="upstream"
UP_URL_HINT="git@github.com:driceroland/Search.git"

usage() {
  sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --fetch) FETCH=1; shift ;;
    --report)
      REPORT="${2:?--report needs a path}"
      shift 2
      ;;
    --base)
      BASE_REF="${2:?--base needs a ref}"
      shift 2
      ;;
    --upstream)
      UP_REF="${2:?--upstream needs a ref}"
      shift 2
      ;;
    -h|--help) usage; exit 0 ;;
    *)
      echo "unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if ! git remote get-url "$UP_REMOTE" >/dev/null 2>&1; then
  echo "missing remote '$UP_REMOTE'. add it with:" >&2
  echo "  git remote add $UP_REMOTE $UP_URL_HINT" >&2
  exit 1
fi

if [[ "$FETCH" -eq 1 ]]; then
  git fetch "$UP_REMOTE" --tags --prune
fi

if ! git rev-parse --verify "$UP_REF" >/dev/null 2>&1; then
  echo "cannot resolve $UP_REF — run with --fetch or: git fetch $UP_REMOTE" >&2
  exit 1
fi

BASE_SHA=$(git rev-parse "$BASE_REF")
UP_SHA=$(git rev-parse "$UP_REF")
MERGE_BASE=$(git merge-base "$BASE_SHA" "$UP_SHA")
AHEAD=$(git rev-list --count "$UP_SHA".."$BASE_SHA")
BEHIND=$(git rev-list --count "$BASE_SHA".."$UP_SHA")
BASE_SHORT=$(git rev-parse --short "$BASE_SHA")
UP_SHORT=$(git rev-parse --short "$UP_SHA")
MB_SHORT=$(git rev-parse --short "$MERGE_BASE")
GENERATED=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
UP_REMOTE_URL=$(git remote get-url "$UP_REMOTE")

TMPDIR_SYNC=$(mktemp -d)
trap 'rm -rf "$TMPDIR_SYNC"' EXIT
TAGS_FILE="$TMPDIR_SYNC/tags.txt"
COMMITS_FILE="$TMPDIR_SYNC/commits.txt"

# Tags reachable from upstream tip but not from base.
: > "$TAGS_FILE"
git tag --merged "$UP_SHA" --no-merged "$BASE_SHA" --sort=-creatordate 2>/dev/null | while read -r tag; do
  [[ -z "$tag" ]] && continue
  tdate=$(git log -1 --format='%ad' --date=short "$tag")
  tsha=$(git rev-parse --short "$tag^{}")
  tsubj=$(git log -1 --format='%s' "$tag")
  printf '%s|%s|%s|%s\n' "$tag" "$tdate" "$tsha" "$tsubj"
done > "$TAGS_FILE"

git log --format='%h|%ad|%s' --date=short "$BASE_SHA".."$UP_SHA" > "$COMMITS_FILE"

is_noise() {
  case "$1" in
    Merge\ *) return 0 ;;
    Roadmap:*) return 0 ;;
    Changelog:*) return 0 ;;
    "./ideas"*) return 0 ;;
    One\ live\ list*) return 0 ;;
    *) return 1 ;;
  esac
}

priority_for() {
  local s
  s=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  # Spaces in subjects: match key tokens without multi-word case arms (bash 3.2).
  case "$s" in
    *password*|*keychain*|*certificate*|*security*|*permission*|*pop-up*|*popup*need*|*appcast*|*updater*|*checksum*|*developer*id*)
      echo "P0-security"
      ;;
    *extension*|*bitwarden*|*1password*|*passkey*)
      echo "P1-extensions"
      ;;
    *⌘w*|*pin*|*space*|*media*|*history*|*full*screen*|*wheel*|*scroll*|*inspector*|*finder*|*attachment*|*content*controller*)
      echo "P1-ux-fix"
      ;;
    *helm*|*breathing*|*site*card*|*folded*tab*|*bench*)
      echo "P2-polish"
      ;;
    *)
      echo "P2-other"
      ;;
  esac
}

files_for() {
  git diff-tree --no-commit-id --name-only -r "$1" | tr '\n' ' ' | sed 's/[[:space:]]*$//'
}

short_files() {
  # Collapse Sources/Search/Foo.swift → `Foo.swift` for the table.
  printf '%s' "$1" | awk '{
    out=""
    for (i=1; i<=NF; i++) {
      f=$i
      sub(/^Sources\/Search\//, "", f)
      if (out != "") out=out ", "
      out=out "`" f "`"
    }
    print out
  }'
}

build_report() {
  cat <<EOF
# Upstream sync report

Generated: \`$GENERATED\` (UTC)

| | |
|---|---|
| Fork base | \`$BASE_REF\` → \`$BASE_SHORT\` |
| Upstream | \`$UP_REF\` → \`$UP_SHORT\` (\`$UP_REMOTE_URL\`) |
| Merge base | \`$MB_SHORT\` |
| Behind upstream | **$BEHIND** commits |
| Ahead of upstream | **$AHEAD** commits |

EOF

  if [[ "$AHEAD" -eq 0 && "$BEHIND" -gt 0 ]]; then
    echo "This fork is a clean ancestor of upstream (fast-forward possible). **Do not mass-merge here** — use the triage list and port selectively."
    echo
  elif [[ "$AHEAD" -gt 0 && "$BEHIND" -gt 0 ]]; then
    echo "Histories have diverged. Prefer cherry-picks / targeted ports over a blind merge."
    echo
  elif [[ "$BEHIND" -eq 0 ]]; then
    echo "Already up to date with \`$UP_REF\`."
    echo
  fi

  cat <<'EOF'
## Releases / tags on upstream not in this base

EOF

  if [[ ! -s "$TAGS_FILE" ]]; then
    echo "_None._"
    echo
  else
    echo "| Tag | Date | Commit | Subject |"
    echo "|---|---|---|---|"
    while IFS='|' read -r tag tdate tsha tsubj; do
      echo "| \`$tag\` | $tdate | \`$tsha\` | $tsubj |"
    done < "$TAGS_FILE"
    echo
  fi

  cat <<'EOF'
## Commits on upstream not in this base

Newest first. Priority is a heuristic from the subject (security / passwords / updater first). Merge and roadmap-only commits are omitted.

| Pri | Commit | Date | Subject | Files |
|---|---|---|---|---|
EOF

  while IFS='|' read -r short date subject; do
    [[ -z "${short:-}" ]] && continue
    if is_noise "$subject"; then
      continue
    fi
    pri=$(priority_for "$subject")
    files=$(files_for "$short")
    files_short=$(short_files "$files")
    echo "| $pri | [\`$short\`](https://github.com/driceroland/Search/commit/$short) | $date | $subject | $files_short |"
  done < "$COMMITS_FILE"

  cat <<'EOF'

## How to re-run

```bash
cd ~/Documents/Codes/Search
./upstream-sync.sh --fetch --report /path/to/report.md
```

Optional refs: `--base origin/main` `--upstream upstream/main`.

Isolated review worktree (does not change this checkout's branch):

```bash
git fetch upstream --tags
git worktree add -b review/upstream-sync worktrees/upstream-sync upstream/main
```

## Porting policy (Project)

- Track and triage here; **do not** mass-port every upstream commit in one go.
- Prefer security / password / updater / extension hardening, then clear UX bugfixes that touch files this fork already owns.
- Skip pure roadmap/changelog/ideas commits unless needed for context.
EOF
}

summary() {
  echo "upstream sync — $GENERATED"
  echo "  base:       $BASE_REF ($BASE_SHORT)"
  echo "  upstream:   $UP_REF ($UP_SHORT)  $UP_REMOTE_URL"
  echo "  merge-base: $MB_SHORT"
  echo "  behind:     $BEHIND"
  echo "  ahead:      $AHEAD"
  if [[ -s "$TAGS_FILE" ]]; then
    tags_list=$(awk -F'|' '{printf "%s ", $1}' "$TAGS_FILE")
    echo "  new tags:   $tags_list"
  else
    echo "  new tags:   (none)"
  fi
  echo
  echo "high-signal commits (noise filtered), newest first:"
  while IFS='|' read -r short date subject; do
    [[ -z "${short:-}" ]] && continue
    is_noise "$subject" && continue
    pri=$(priority_for "$subject")
    printf '  %-14s %s  %s  %s\n' "$pri" "$short" "$date" "$subject"
  done < "$COMMITS_FILE"
}

summary

if [[ -n "$REPORT" ]]; then
  mkdir -p "$(dirname "$REPORT")"
  build_report > "$REPORT"
  echo
  echo "wrote report: $REPORT"
fi
