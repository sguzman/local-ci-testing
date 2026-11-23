#!/usr/bin/env fish

# Execute GitHub Actions locally and publish linked diagnostics without Docker.
# Full logs are local; GitHub gets a bounded, best-effort-redacted excerpt.
set -l workflow .github/workflows/ci.yml
set -l context local-ci/wrkflw-host

function fail --argument-names message
    printf 'ERROR: %s\n' "$message" >&2
    exit 1
end

set -l root (git rev-parse --show-toplevel 2>/dev/null)
if test -z "$root"
    fail 'Run this from inside a Git repository.'
end
cd "$root"; or exit 1

set -l dirty (git status --porcelain --untracked-files=normal)
if test (count $dirty) -gt 0
    fail 'Commit or discard changes before publishing a status for HEAD.'
end

if not gh auth status --hostname github.com >/dev/null 2>&1
    fail 'GitHub CLI needs authentication: nix develop --command gh auth login'
end

set -l repo (gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null)
if test -z "$repo"
    fail 'Could not determine the GitHub repository from this checkout.'
end

set -l sha (git rev-parse HEAD)
if not gh api "repos/$repo/commits/$sha" --jq .sha >/dev/null
    fail 'Commit is not accessible on GitHub; push it before reporting CI.'
end

# Keep log files inside Git metadata, away from the working tree.
set -l log_dir (git rev-parse --git-path local-ci)
mkdir -p "$log_dir"; or fail 'Could not create the local CI log directory.'
set -l stamp (date -u +%Y%m%dT%H%M%SZ)
set -l started (date -u +%Y-%m-%dT%H:%M:%SZ)
set -l start_seconds (date +%s)
set -l log "$log_dir/$sha-$stamp.log"
set -l excerpt "$log_dir/$sha-$stamp.excerpt.txt"
set -l report "$log_dir/$sha-$stamp.report.md"

echo "Running $workflow locally for $repo @ $sha"
echo "Full log: $log"

# Fish pipestatus[1] is wrkflw's exit code, not tee's.
wrkflw validate "$workflow" 2>&1 | tee "$log"
set -l ci_exit $pipestatus[1]
if test $ci_exit -eq 0
    wrkflw run --runtime emulation "$workflow" 2>&1 | tee -a "$log"
    set ci_exit $pipestatus[1]
end

set -l state failure
set -l label FAILED
set -l detail "Local wrkflw host-emulation failed (exit $ci_exit)"
if test $ci_exit -eq 0
    set state success
    set label PASSED
    set detail 'Local wrkflw host-emulation workflow passed'
end
set -l finished (date -u +%Y-%m-%dT%H:%M:%SZ)
set -l duration (math (date +%s) - $start_seconds)

# WARNING: Redaction is best-effort. Arbitrary commands can print secrets.
# Upload the last 120 lines only, not the full log.
tail -n 120 "$log" | sed -E \
    -e '/-----BEGIN [A-Z ]*PRIVATE KEY-----/,/-----END [A-Z ]*PRIVATE KEY-----/c\[private key material omitted]' \
    -e 's/(gh[pousr]_[A-Za-z0-9_]{16,}|github_pat_[A-Za-z0-9_]{16,}|AKIA[A-Z0-9]{16})/[REDACTED_TOKEN]/g' \
    -e 's/(Bearer[[:space:]]+)[A-Za-z0-9._-]+/\1[REDACTED]/Ig' \
    -e 's#(https?://)[^:/[:space:]]+:[^@[:space:]]+@#\1[REDACTED]@#g' \
    -e 's#(/home/)[^/[:space:]]+#\1[user]#g' \
    -e 's/((TOKEN|PASSWORD|SECRET|API_KEY|PRIVATE_KEY)[[:space:]]*[:=][[:space:]]*)[^[:space:]]+/\1[REDACTED]/Ig' \
    -e 's/~~~/~ ~ ~/g' > "$excerpt"

printf '### Local CI: %s\n\n' "$label" > "$report"
printf '%s\n' \
    '- **Reporter:** local-ci/wrkflw-host' \
    "- **Repository:** $repo" \
    "- **Commit:** $sha" \
    "- **Workflow:** $workflow" \
    '- **Runtime:** wrkflw host emulation (no containers)' \
    "- **Started (UTC):** $started" \
    "- **Finished (UTC):** $finished" \
    "- **Duration:** $duration seconds" \
    "- **Exit code:** $ci_exit" \
    '' \
    'This is an external local CI result, not a native GitHub Actions run.' \
    'Full logs remain on the runner under .git/local-ci/.' \
    'The excerpt has best-effort credential filtering. Do not assume it is safe for arbitrary sensitive logs.' \
    '' \
    '<details><summary>Diagnostic output (last 120 lines; redacted)</summary>' \
    '' \
    '~~~text' >> "$report"
cat "$excerpt" >> "$report"
printf '\n~~~\n</details>\n' >> "$report"

# A commit comment is accessible within the repo; use it as the check's
# Details destination. It does not require a custom GitHub App.
set -l report_url (gh api --method POST "repos/$repo/commits/$sha/comments" \
    -F "body=@$report" --jq .html_url 2>/dev/null)
if test -z "$report_url"
    echo 'WARNING: Could not upload CI report; GitHub Contents: write permission is required.' >&2
end

if test -n "$report_url"
    gh api --method POST "repos/$repo/statuses/$sha" \
        -f "state=$state" -f "context=$context" \
        -f "description=$detail" -f "target_url=$report_url" >/dev/null
else
    gh api --method POST "repos/$repo/statuses/$sha" \
        -f "state=$state" -f "context=$context" \
        -f "description=$detail" >/dev/null
end
set -l publish_exit $status
if test $publish_exit -ne 0
    echo 'ERROR: The workflow ran, but its commit status could not be published.' >&2
    exit 1
end

printf 'Published %s: %s\n' "$context" "$state"
if test -n "$report_url"
    printf 'GitHub report: %s\n' "$report_url"
else
    echo 'WARNING: GitHub status has no linked report.' >&2
end
if test $ci_exit -ne 0
    exit $ci_exit
end
if test -z "$report_url"
    exit 1
end
exit 0
