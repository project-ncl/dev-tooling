#!/usr/bin/env bash
#
# merge-prs.sh - merge open PRs across a GitHub org whose title matches a pattern,
# but only when CI has passed. Deletes the head branch afterwards.
#
# DRY-RUN BY DEFAULT: nothing is changed unless --execute is given.
#
# Requires: gh (authenticated, 'repo' scope), jq.

set -uo pipefail

OWNER="project-ncl"
PATTERN=""
REPOS=()
AUTHORS=()
METHOD="auto"
EXECUTE=0
KEEP_BRANCH=0
DEBUG=0
COLOR=auto
ALLOW_NO_CHECKS=0
LIMIT=300
MERGE_DELAY=2

usage() {
    cat <<'EOF'
Usage: merge-prs.sh -p REGEX [options]

Merges open PRs whose title matches REGEX, only if CI has passed, then deletes
the head branch. DRY-RUN BY DEFAULT: use --execute to actually merge.

Options:
  -p, --pattern REGEX     Title regex (ERE, case-insensitive). Required.
                          e.g. 'shared-github-actions'
  -o, --owner ORG         GitHub org/user to search (default: project-ncl)
  -r, --repo NAME         Restrict to this repo name (repeatable; default: all)
  -a, --author LOGIN      PR author (repeatable; default: app/dependabot;
                          use 'any' to disable the author filter)
  -m, --method METHOD     rebase|merge|squash|auto (default: auto). auto picks per
                          repo: rebase if allowed, else merge, else squash.
  -x, --execute           Actually merge and delete branches (default: dry-run)
  -n, --dry-run           Report only (this is the default; accepted for clarity)
      --keep-branch       Do not delete the head branch after merging
  -d, --debug             Verbose output: per-PR state (head SHA, mergeable, merge
                          state, review, CI, method) and workflow files touched
      --color             Force coloured output (default: only when stdout is a
                          terminal and NO_COLOR is unset)
      --no-color          Disable coloured output
      --allow-no-checks   Treat PRs that have no checks at all as passing
  -l, --limit N           Max PRs fetched from search (default: 300)
  -h, --help              Show this help

A PR is merged only if: open, not draft, no merge conflicts, not blocked by
branch protection / required reviews, and every check has completed successfully.
PRs whose CI is still pending are skipped (and logged) - re-run later.
PRs that are merely BEHIND the base branch are still merged; they only need a
rebase if GitHub reports conflicts.

Exit status: 1 if any merge attempt failed, 2 on usage/setup errors, else 0.
EOF
}

# Colours are set up by init_colors after option parsing; empty until then.
C_RESET="" C_DIM="" C_GREEN="" C_YELLOW="" C_CYAN="" C_BOLD_RED=""

init_colors() {
    if [[ "$COLOR" == "auto" ]]; then
        if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then COLOR=always; else COLOR=never; fi
    fi
    [[ "$COLOR" == "always" ]] || return 0
    C_RESET=$'\033[0m'      C_DIM=$'\033[2m'
    C_GREEN=$'\033[32m'     C_YELLOW=$'\033[33m'
    C_CYAN=$'\033[36m'      C_BOLD_RED=$'\033[1;31m'
}

# Colour for a log level / summary status word.
color_for() {
    case "$1" in
        CHECK)           printf '%s' "$C_GREEN" ;;
        DRY|WOULD)       printf '%s' "$C_CYAN" ;;
        WARN|SKIP|SKIPPED) printf '%s' "$C_YELLOW" ;;
        ERROR|FAILED)    printf '%s' "$C_BOLD_RED" ;;
        DEBUG)           printf '%s' "$C_DIM" ;;
    esac
}

log() {
    [[ "$1" == "DEBUG" && $DEBUG -eq 0 ]] && return 0
    # CHECK is an INFO line shown in colour; it is printed with the label INFO.
    local c label="$1"; c=$(color_for "$1")
    [[ "$1" == "CHECK" ]] && label="INFO"
    printf '%s%s [%s] %s%s\n' "$c" "$(date +%H:%M:%S)" "$label" "${*:2}" "${c:+$C_RESET}"
}
die() { log ERROR "$*" >&2; exit 2; }

# ---------------------------------------------------------------- arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        -p|--pattern)      PATTERN="${2:?missing value for $1}"; shift 2 ;;
        -o|--owner)        OWNER="${2:?missing value for $1}"; shift 2 ;;
        -r|--repo)         REPOS+=("${2:?missing value for $1}"); shift 2 ;;
        -a|--author)       AUTHORS+=("${2:?missing value for $1}"); shift 2 ;;
        -m|--method)       METHOD="${2:?missing value for $1}"; shift 2 ;;
        -l|--limit)        LIMIT="${2:?missing value for $1}"; shift 2 ;;
        -x|--execute)      EXECUTE=1; shift ;;
        -n|--dry-run)      EXECUTE=0; shift ;;
        --keep-branch)     KEEP_BRANCH=1; shift ;;
        -d|--debug)        DEBUG=1; shift ;;
        --color)           COLOR=always; shift ;;
        --no-color)        COLOR=never; shift ;;
        --allow-no-checks) ALLOW_NO_CHECKS=1; shift ;;
        -h|--help)         usage; exit 0 ;;
        *) usage >&2; die "Unknown option: $1" ;;
    esac
done

init_colors
[[ -n "$PATTERN" ]] || { usage >&2; die "--pattern is required"; }
case "$METHOD" in auto|rebase|merge|squash) ;; *) die "Invalid --method: $METHOD" ;; esac
[[ "$LIMIT" =~ ^[0-9]+$ ]] || die "--limit must be a number"
[[ ${#AUTHORS[@]} -gt 0 ]] || AUTHORS=("app/dependabot")

# ---------------------------------------------------------------- preflight
command -v gh >/dev/null || die "gh not found"
command -v jq >/dev/null || die "jq not found"
gh auth status >/dev/null 2>&1 || die "gh is not authenticated (run: gh auth login)"

# Rebase/squash merges rewrite commits; GitHub refuses that for PRs touching
# .github/workflows/* unless the token has the 'workflow' scope.
if ! gh auth status 2>&1 | grep -E "Token scopes:" | grep -q "'workflow'"; then
    log WARN "gh token lacks the 'workflow' scope: merging PRs that change .github/workflows/* may fail."
    log WARN "Fix with: gh auth refresh -h github.com -s workflow"
fi

if [[ $EXECUTE -eq 1 ]]; then
    log INFO "MODE: EXECUTE (PRs will be merged)"
else
    log INFO "MODE: DRY-RUN (no changes; use --execute to merge)"
fi

# ---------------------------------------------------------------- discovery
search_json="[]"
for author in "${AUTHORS[@]}"; do
    # shellcheck disable=SC2054  # the comma is part of the gh --json field list
    args=(search prs --owner "$OWNER" --state open --archived=false --limit "$LIMIT"
          --json repository,number,title,url)
    [[ "$author" == "any" ]] || args+=(--author "$author")
    out=$(gh "${args[@]}") || die "gh search failed for author '$author'"
    search_json=$(jq -s 'add' <(echo "$search_json") <(echo "$out"))
done

repos_json=$(printf '%s\n' "${REPOS[@]+"${REPOS[@]}"}" | jq -R . | jq -s 'map(select(length>0))')

# Tab-separated: repo<TAB>number<TAB>url<TAB>title ; filtered, de-duplicated, ordered
mapfile -t PRS < <(jq -r --arg p "$PATTERN" --argjson repos "$repos_json" '
    map(select(.title | test($p; "i")))
    | map(select(($repos | length) == 0 or (.repository.name as $n | $repos | index($n))))
    | unique_by(.repository.nameWithOwner + "#" + (.number|tostring))
    | sort_by(.repository.nameWithOwner, .number)
    | .[] | [.repository.nameWithOwner, .number, .url, .title] | @tsv' <<<"$search_json")

log INFO "Found ${#PRS[@]} open PR(s) matching /$PATTERN/ (authors: ${AUTHORS[*]})"
[[ ${#PRS[@]} -gt 0 ]] || exit 0

# ---------------------------------------------------------------- helpers
declare -A REPO_METHOD REPO_DEFAULT_BRANCH

# Populates REPO_METHOD / REPO_DEFAULT_BRANCH for a repo (cached).
load_repo() {
    local repo="$1" info
    [[ -n "${REPO_METHOD[$repo]:-}" ]] && return 0
    info=$(gh api "repos/$repo" --jq '[.allow_rebase_merge,.allow_merge_commit,.allow_squash_merge,.default_branch]|@tsv') \
        || return 1
    local rebase merge squash branch
    IFS=$'\t' read -r rebase merge squash branch <<<"$info"
    REPO_DEFAULT_BRANCH[$repo]="$branch"
    if [[ "$METHOD" != "auto" ]]; then
        local allowed=false
        case "$METHOD" in rebase) allowed=$rebase ;; merge) allowed=$merge ;; squash) allowed=$squash ;; esac
        if [[ "$allowed" != "true" ]]; then
            REPO_METHOD[$repo]="NONE"
        else
            REPO_METHOD[$repo]="$METHOD"
        fi
    elif [[ "$rebase" == "true" ]]; then REPO_METHOD[$repo]="rebase"
    elif [[ "$merge" == "true" ]]; then  REPO_METHOD[$repo]="merge"
    elif [[ "$squash" == "true" ]]; then REPO_METHOD[$repo]="squash"
    else REPO_METHOD[$repo]="NONE"
    fi
}

# Prints: pass | pending | fail | none   (aggregate over all checks/statuses)
ci_state() {
    jq -r '
      (.statusCheckRollup // []) as $c
      | if ($c | length) == 0 then "none" else
          [ $c[] |
            if .__typename == "CheckRun" then
              (if .status != "COMPLETED" then "pending"
               elif (.conclusion | IN("SUCCESS","NEUTRAL","SKIPPED")) then "ok"
               else "fail" end)
            else
              (if .state == "SUCCESS" then "ok"
               elif (.state | IN("PENDING","EXPECTED")) then "pending"
               else "fail" end)
            end
          ] as $s
          | if ($s | index("fail")) then "fail"
            elif ($s | index("pending")) then "pending"
            else "pass" end
        end' <<<"$1"
}

# Prints names of checks that are not successful (for logging).
ci_problems() {
    jq -r '
      [ (.statusCheckRollup // [])[]
        | select(
            if .__typename == "CheckRun"
            then (.status != "COMPLETED") or (.conclusion | IN("SUCCESS","NEUTRAL","SKIPPED") | not)
            else (.state != "SUCCESS") end)
        | (.name // .context) + "=" + ((.conclusion // .state // .status) | tostring)
      ] | join(", ")' <<<"$1"
}

MERGED=0 SKIPPED=0 FAILED=0 WOULD=0
declare -a SUMMARY

# Summary line: status, PR ref, PR title (the loop's $title), plus optional reason.
record() { # status ref [reason]
    local detail="$title"
    [[ -z "${3:-}" ]] || detail="$title  -- $3"
    SUMMARY+=("$(printf '%-9s %-40s %s' "$1" "$2" "$detail")")
}

skip() { # ref reason
    SKIPPED=$((SKIPPED + 1))
    log SKIP "$1 - $2"
    record SKIPPED "$1" "$2"
}

# ---------------------------------------------------------------- main loop
for row in "${PRS[@]}"; do
    IFS=$'\t' read -r repo number url title <<<"$row"
    ref="$repo#$number"
    log CHECK "Checking $ref: $title"

    if ! load_repo "$repo"; then
        FAILED=$((FAILED + 1)); log ERROR "$ref - could not read repo settings"
        record FAILED "$ref" "cannot read repo settings"; continue
    fi
    method="${REPO_METHOD[$repo]}"
    if [[ "$method" == "NONE" ]]; then
        skip "$ref" "no allowed merge method (requested: $METHOD)"; continue
    fi

    # Re-read PR state right before acting. mergeable can be UNKNOWN while
    # GitHub recomputes it (e.g. just after a sibling PR was merged).
    pr=""
    for _ in 1 2 3 4 5; do
        pr=$(gh pr view "$number" -R "$repo" --json \
            state,isDraft,mergeable,mergeStateStatus,reviewDecision,headRefName,headRefOid,isCrossRepository,statusCheckRollup) \
            || { pr=""; break; }
        [[ "$(jq -r .mergeable <<<"$pr")" != "UNKNOWN" ]] && break
        sleep 2
    done
    if [[ -z "$pr" ]]; then
        FAILED=$((FAILED + 1)); log ERROR "$ref - could not read PR"
        record FAILED "$ref" "cannot read PR"; continue
    fi

    state=$(jq -r .state <<<"$pr")
    draft=$(jq -r .isDraft <<<"$pr")
    mergeable=$(jq -r .mergeable <<<"$pr")
    mstate=$(jq -r .mergeStateStatus <<<"$pr")
    review=$(jq -r '.reviewDecision // ""' <<<"$pr")
    branch=$(jq -r .headRefName <<<"$pr")
    sha=$(jq -r .headRefOid <<<"$pr")
    cross=$(jq -r .isCrossRepository <<<"$pr")

    [[ "$state" == "OPEN" ]] || { skip "$ref" "state is $state"; continue; }
    [[ "$draft" == "false" ]] || { skip "$ref" "draft PR"; continue; }

    # Conflicts are the only reason a PR needs rebasing. BEHIND is fine.
    if [[ "$mergeable" == "CONFLICTING" || "$mstate" == "DIRTY" ]]; then
        skip "$ref" "merge conflicts (needs manual rebase)"; continue
    fi
    if [[ "$mergeable" != "MERGEABLE" ]]; then
        skip "$ref" "mergeable=$mergeable (state $mstate)"; continue
    fi
    case "$review" in
        CHANGES_REQUESTED|REVIEW_REQUIRED) skip "$ref" "review decision: $review"; continue ;;
    esac

    # CI gate.
    ci=$(ci_state "$pr")
    case "$ci" in
        pass) ;;
        pending) skip "$ref" "CI still pending ($(ci_problems "$pr")) - retry later"; continue ;;
        fail)    skip "$ref" "CI failed ($(ci_problems "$pr"))"; continue ;;
        none)
            if [[ $ALLOW_NO_CHECKS -eq 1 ]]; then
                log WARN "$ref has no checks; merging due to --allow-no-checks"
            else
                skip "$ref" "no CI checks reported (use --allow-no-checks to override)"; continue
            fi ;;
    esac

    # BLOCKED here means branch protection requirements beyond what we can see.
    if [[ "$mstate" == "BLOCKED" ]]; then
        skip "$ref" "blocked by branch protection (CI ok, state BLOCKED)"; continue
    fi

    note=""
    [[ "$mstate" == "BEHIND" ]] && note=" (behind base, no conflicts)"

    if [[ $DEBUG -eq 1 ]]; then
        log DEBUG "$ref - head=${sha:0:8} mergeable=$mergeable state=$mstate review='${review:-none}' ci=$ci method=$method"
        # Rebase/squash merges rewrite commits, which GitHub only allows for
        # workflow files when the token has the 'workflow' scope.
        wf_files=$(gh pr view "$number" -R "$repo" --json files \
            --jq '[.files[].path | select(startswith(".github/workflows/"))] | join(", ")' 2>/dev/null)
        [[ -z "$wf_files" ]] || log DEBUG "$ref - touches workflow file(s): $wf_files"
    fi

    if [[ $EXECUTE -eq 0 ]]; then
        WOULD=$((WOULD + 1))
        log DRY "WOULD MERGE $ref via $method$note; would delete branch $branch"
        record WOULD "$ref"
        continue
    fi

    if out=$(gh pr merge "$number" -R "$repo" "--$method" --match-head-commit "$sha" 2>&1); then
        MERGED=$((MERGED + 1))
        log OK "MERGED $ref via $method$note"
        record MERGED "$ref"
    else
        FAILED=$((FAILED + 1))
        log ERROR "$ref merge failed: ${out//$'\n'/ }"
        if [[ "$out" == *"without \`workflow\` scope"* ]]; then
            log ERROR "Hint: the token needs the 'workflow' scope to merge PRs that change workflow files."
            log ERROR "Fix: gh auth refresh -h github.com -s workflow  (or comment '@dependabot rebase' on $url)"
        fi

        record FAILED "$ref" "merge failed: ${out//$'\n'/ }"
        continue
    fi

    # Branch deletion (explicit; many repos do not auto-delete).
    if [[ $KEEP_BRANCH -eq 1 ]]; then
        log INFO "$ref - keeping branch $branch (--keep-branch)"
    elif [[ "$cross" == "true" ]]; then
        log INFO "$ref - head is in a fork; not deleting branch"
    elif [[ "$branch" == "${REPO_DEFAULT_BRANCH[$repo]}" ]]; then
        log WARN "$ref - head branch is the default branch; not deleting"
    elif del=$(gh api -X DELETE "repos/$repo/git/refs/heads/$branch" 2>&1); then
        log OK "$ref - deleted branch $branch"
    elif [[ "$del" == *"Reference does not exist"* || "$del" == *"Not Found"* ]]; then
        log INFO "$ref - branch $branch already deleted"
    else
        log WARN "$ref - could not delete branch $branch: ${del//$'\n'/ }"
    fi

    sleep "$MERGE_DELAY"
done

# ---------------------------------------------------------------- summary
echo
log INFO "Summary"
printf '%s\n' "${SUMMARY[@]}"
echo
if [[ $EXECUTE -eq 1 ]]; then
    log INFO "merged=$MERGED skipped=$SKIPPED failed=$FAILED"
else
    log INFO "DRY-RUN: would_merge=$WOULD skipped=$SKIPPED failed=$FAILED (re-run with --execute to merge)"
fi

[[ $FAILED -eq 0 ]] || exit 1
exit 0
