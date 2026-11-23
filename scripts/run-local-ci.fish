#!/usr/bin/env fish

# Run the repository's GitHub Actions workflow locally, then report its result
# as a separate GitHub commit status. No Docker or GitHub Actions minutes.
set -l workflow .github/workflows/ci.yml
set -l context local-ci/wrkflw-host

function fail --argument-names message
    printf 'ERROR: %s\n' "$message" >&2
    exit 1
end

# Work relative to the repository, even when invoked from a subdirectory.
set -l root (git rev-parse --show-toplevel 2>/dev/null)
if test -z "$root"
    fail 'Run this from inside a Git repository.'
end
cd "$root"; or exit 1

# A GitHub status refers to a commit, not uncommitted working-tree changes.
if test -n "$(git status --porcelain --untracked-files=normal)"
    fail 'Working tree is dirty. Commit or discard changes before publishing a status.'
end

if not gh auth status --hostname github.com >/dev/null 2>&1
    fail 'GitHub CLI is not authenticated. Run: nix develop --command gh auth login'
end

set -l repo (gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null)
if test -z "$repo"
    fail 'Could not determine the GitHub repository from this checkout.'
end

set -l sha (git rev-parse HEAD)
if not gh api "repos/$repo/commits/$sha" --jq .sha >/dev/null
    fail 'Commit is not accessible on GitHub. Push it first, then retry.'
end

echo "Running $workflow locally for $repo @ $sha"
echo "The GitHub status context will be: $context"

wrkflw validate "$workflow"
set -l ci_exit $status
if test $ci_exit -eq 0
    wrkflw run --runtime emulation "$workflow"
    set ci_exit $status
end

if test $ci_exit -eq 0
    set -l state success
    set -l detail 'Local wrkflw host-emulation workflow passed'
else
    set -l state failure
    set -l detail "Local wrkflw host-emulation workflow failed (exit $ci_exit)"
end

# Only report the result of the actual run. Do not claim a native Actions
# run or overwrite the GitHub-hosted job's check context.
if not gh api --method POST "repos/$repo/statuses/$sha" \
    -f "state=$state" \
    -f "context=$context" \
    -f "description=$detail" >/dev/null
    echo 'ERROR: CI ran, but its status could not be published.' >&2
    echo 'GitHub credentials need Commit statuses: write permission.' >&2
    exit 1
end

echo "Published $context: $state"
echo "https://github.com/$repo/commit/$sha"
exit $ci_exit
