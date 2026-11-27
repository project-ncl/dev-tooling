#!/usr/bin/env bash
#
# pr-stats.sh - count the PRs a user authored over a date range (default:
# year to date) and show which repositories they were raised in.
#
# The range is split into 30-day windows because a single GitHub search returns
# at most 1000 results.
#
# Requires: gh (authenticated for the chosen host), jq, GNU date.

set -uo pipefail

USER_NAME="@me"
HOST="github.com"
FROM=""
TO=""
SORT="total"
WINDOW=30
KEEP_FILE=""

usage() {
    cat <<'EOF'
Usage: pr-stats.sh [options]

Counts PRs authored over a date range and prints totals plus a per-repository
breakdown. By default the range is the year to date: 1 January of the current
year up to today.

Options:
  -u, --user LOGIN    PR author (default: @me, i.e. the authenticated user)
  -H, --host HOST     GitHub host (default: github.com), e.g. github.<mycompany>.com
  -f, --from DATE     Start date, YYYY-MM-DD (default: 1 January of the --to year)
  -t, --to DATE       End date, YYYY-MM-DD (default: today)
  -s, --sort KEY      Sort repositories by 'total' (default, highest first) or
                      'repo' (alphabetical)
  -k, --keep FILE     Also keep the raw PR data (JSON lines) in FILE
  -h, --help          Show this help

Examples:
  pr-stats.sh
  pr-stats.sh -H github.<mycompany>.com
  pr-stats.sh -s repo
  pr-stats.sh -f "$(date -d '1 year ago' +%F)"   # rolling last 12 months
  pr-stats.sh -f 2026-01-01 -t 2026-06-30
  pr-stats.sh -u octocat -k octocat-prs.json
EOF
}

log() { printf '%s [%s] %s\n' "$(date +%H:%M:%S)" "$1" "${*:2}" >&2; }
die() { log ERROR "$*"; exit 2; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        -u|--user) USER_NAME="${2:?missing value for $1}"; shift 2 ;;
        -H|--host) HOST="${2:?missing value for $1}"; shift 2 ;;
        -f|--from) FROM="${2:?missing value for $1}"; shift 2 ;;
        -t|--to)   TO="${2:?missing value for $1}"; shift 2 ;;
        -s|--sort) SORT="${2:?missing value for $1}"; shift 2 ;;
        -k|--keep) KEEP_FILE="${2:?missing value for $1}"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; die "Unknown option: $1" ;;
    esac
done

command -v gh >/dev/null || die "gh not found"
command -v jq >/dev/null || die "jq not found"
date -d "today" +%F >/dev/null 2>&1 || die "GNU date is required"
gh auth status --hostname "$HOST" >/dev/null 2>&1 \
    || die "gh is not authenticated for $HOST (run: gh auth login --hostname $HOST)"

DATA=$(mktemp) || die "cannot create temp file"
trap 'rm -f "$DATA"' EXIT

valid_date() { [[ "$1" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] && date -d "$1" +%F >/dev/null 2>&1; }

case "$SORT" in total|repo) ;; *) die "invalid --sort: $SORT (expected total or repo)" ;; esac
today=$(date +%F)
end="${TO:-$today}"
valid_date "$end" || die "invalid --to date: $end (expected YYYY-MM-DD)"
if [[ -n "$FROM" ]]; then
    valid_date "$FROM" || die "invalid --from date: $FROM (expected YYYY-MM-DD)"
    start="$FROM"
else
    start="${end%%-*}-01-01"
fi
[[ ! "$start" > "$end" ]] || die "start date $start is after end date $end"
log INFO "Searching PRs by '$USER_NAME' on $HOST from $start to $end"

QUERY='
query($q: String!, $endCursor: String) {
  search(query: $q, type: ISSUE, first: 100, after: $endCursor) {
    pageInfo { hasNextPage endCursor }
    nodes {
      ... on PullRequest {
        state
        repository { nameWithOwner }
      }
    }
  }
}'

from="$start"
while [[ ! "$from" > "$end" ]]; do
    to=$(date -d "$from + $((WINDOW - 1)) days" +%F)
    [[ "$to" < "$end" ]] || to="$end"
    range="$from..$to"

    before=$(wc -l <"$DATA")
    gh api graphql --hostname "$HOST" --paginate -f query="$QUERY" \
        -f q="is:pr author:$USER_NAME created:$range" \
        --jq '.data.search.nodes[]' >>"$DATA" || die "search failed for $range"
    found=$(( $(wc -l <"$DATA") - before ))

    log INFO "$range -> $found PRs"
    [[ $found -lt 1000 ]] || log WARN "$range hit the 1000 result search limit; counts are incomplete"

    from=$(date -d "$to + 1 day" +%F)
done

[[ -z "$KEEP_FILE" ]] || cp "$DATA" "$KEEP_FILE"

echo
echo "PRs by $USER_NAME on $HOST, $start to $end"
jq -rs '
  def merged: [.[] | select(.state == "MERGED")] | length;
  "Total:    \(length)",
  "Merged:   \(merged)",
  "Unmerged: \(length - merged)",
  "Repos:    \(group_by(.repository.nameWithOwner) | length)"
' "$DATA"
echo
jq -rs --arg sort "$SORT" '
  def merged: [.[] | select(.state == "MERGED")] | length;
  (["TOTAL", "MERGED", "UNMERGED", "REPOSITORY"] | @tsv),
  ( group_by(.repository.nameWithOwner)
    | map({repo: .[0].repository.nameWithOwner, total: length, merged: merged})
    | if $sort == "repo" then sort_by(.repo | ascii_downcase)
      else sort_by(-.total, (.repo | ascii_downcase)) end
    | .[] | [.total, .merged, (.total - .merged), .repo] | @tsv )
' "$DATA" | column -t -s $'\t'
