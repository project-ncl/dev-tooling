# dev-tooling

Useful utilities for developing PNC.

## Tools

| Tool | Description |
|------|-------------|
| [`merge-prs.sh`](merge-prs.sh) | Bulk-merge open PRs across a GitHub organisation (or selected repos) whose title matches a pattern, once CI has passed. |

## merge-prs.sh

Many repositories receive near-identical PRs at the same time, for example
Dependabot bumping `shared-github-actions` in every repo. `merge-prs.sh` finds
them all, checks that each is safe to merge, merges it, and deletes its branch.

**It is a dry run by default.** Nothing is changed unless you pass `--execute`.

### Requirements

- [`gh`](https://cli.github.com/), authenticated (`gh auth login`) with the `repo` scope
- [`jq`](https://jqlang.github.io/jq/)
- Bash 4+ (uses associative arrays and `mapfile`)

To merge PRs that change `.github/workflows/*`, the token also needs the
`workflow` scope:

```sh
gh auth refresh -h github.com -s workflow
```

### Usage

```sh
# See what would be merged (dry run)
./merge-prs.sh -p 'shared-github-actions'

# Actually merge
./merge-prs.sh -p 'shared-github-actions' --execute

# Restrict to some repos
./merge-prs.sh -p 'shared-github-actions' -r bacon -r pnc --execute

# Include PRs from any author, not just Dependabot
./merge-prs.sh -p 'shared-github-actions' -a any

# Approve PRs that are waiting for a review, then merge them
./merge-prs.sh -p 'shared-github-actions' --approve --execute
```

### Options

| Option | Description |
|--------|-------------|
| `-p, --pattern REGEX` | PR title regex (ERE, case-insensitive). **Required.** |
| `-o, --owner ORG` | GitHub org or user to search (default: `project-ncl`). |
| `-r, --repo NAME` | Restrict to this repo name. Repeatable. Default: all repos. |
| `-a, --author LOGIN` | PR author. Repeatable. Default: `app/dependabot`. Use `any` to disable the filter. |
| `-m, --method METHOD` | `rebase`, `merge`, `squash` or `auto` (default). `auto` picks per repo: rebase if allowed, else merge, else squash. |
| `-x, --execute` | Actually merge and delete branches. |
| `-n, --dry-run` | Report only. This is the default. |
| `--keep-branch` | Do not delete the head branch after merging. |
| `-d, --debug` | Verbose per-PR output (head SHA, mergeable state, review, CI, method, workflow files touched). |
| `--color` / `--no-color` | Force or disable coloured output. Default: colour only on a terminal and when `NO_COLOR` is unset. |
| `--allow-no-checks` | Treat PRs with no checks at all as passing. |
| `--approve` | Approve PRs that are waiting for a review (`REVIEW_REQUIRED`) once every other check has passed, then merge them. Off by default. |
| `--approve-body TEXT` | Comment submitted with the approval. Default: none. |
| `-l, --limit N` | Maximum PRs fetched from search (default: 300). |
| `-h, --help` | Show help. |

### When a PR is merged

A PR is merged only if it is:

- open and not a draft
- free of merge conflicts
- not blocked by branch protection or required reviews (unless `--approve`
  satisfies them)
- passing on every check

Otherwise it is skipped and the reason is logged. Notes:

- PRs whose CI is still **pending** are skipped. Re-run the script later.
- With `--approve`, a PR that needs a review is approved only after it passes
  every other check. The approval is pinned to the checked head commit. PRs with
  requested changes are never approved. Your own PRs are skipped, because GitHub
  does not allow self-approval. A PR that is still blocked after approval (for
  example, because two reviewers are required) is skipped.
  Combining `--approve` with `-a any` prints a warning.
- PRs that are merely **behind** the base branch are still merged. They only
  need a rebase if GitHub reports conflicts.
- Each merge is pinned to the head commit that was checked
  (`--match-head-commit`), so a PR that changes after the check is not merged.

A summary of every PR and its outcome is printed at the end.

### Exit status

| Code | Meaning |
|------|---------|
| `0` | Success (including a dry run, and runs where PRs were skipped). |
| `1` | At least one merge or approval attempt failed. |
| `2` | Usage or setup error (bad option, missing `gh`/`jq`, not authenticated). |

## License

[Apache License 2.0](LICENSE)
