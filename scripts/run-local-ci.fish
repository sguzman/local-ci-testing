#!/usr/bin/env fish

# Run GitHub Actions locally, then publish native GitHub Checks using one
# account-wide GitHub App. No Docker; the key never enters the Nix store.
set -l workflow .github/workflows/ci.yml
set -l check_name 'Local CI (wrkflw/Nix)'
set -l app_dir "$HOME/.config/local-ci"
set -l app_id_file "$app_dir/app-id"
set -l app_key_file "$app_dir/github-app.pem"

function fail --argument-names message
    printf 'ERROR: %s\n' "$message" >&2
    exit 1
end

function base64url
    base64 -w 0 | string replace -a '+' '-' | string replace -a '/' '_' | string trim -c '='
end

# Generate a fresh 1-hour installation token; refresh after long builds.
function new_installation_token --argument-names app_id key_file repo
    set -l now (date +%s)
    set -l issued (math $now - 60)
    set -l expires (math $now + 540)
    set -l header (printf '%s' '{"alg":"RS256","typ":"JWT"}' | base64url)
    set -l claims (jq -nc --argjson iat "$issued" --argjson exp "$expires" \
        --arg iss "$app_id" '{iat:$iat,exp:$exp,iss:$iss}' | base64url)
    if test -z "$header" -o -z "$claims"
        return 1
    end
    set -l signing_input "$header.$claims"
    set -l signature (printf '%s' "$signing_input" | openssl dgst -sha256 \
        -sign "$key_file" -binary 2>/dev/null | base64url)
    if test -z "$signature"
        return 1
    end
    set -l jwt "$signing_input.$signature"

    # Discover installation from the repo; no per-repository configuration.
    set -l installation_id (gh api -H "Authorization: Bearer $jwt" \
        "repos/$repo/installation" --jq .id 2>/dev/null)
    if not string match -rq '^[0-9]+$' -- "$installation_id"
        return 1
    end

    gh api --method POST -H "Authorization: Bearer $jwt" \
        "app/installations/$installation_id/access_tokens" --jq .token 2>/dev/null
end

set -l root (git rev-parse --show-toplevel 2>/dev/null)
if test -z "$root"
    fail 'Run this inside a Git repository.'
end
cd "$root"; or exit 1

set -l dirty (git status --porcelain --untracked-files=normal)
if test (count $dirty) -gt 0
    fail 'Working tree is dirty; a Check Run must identify the exact tested commit.'
end

if not gh auth status --hostname github.com >/dev/null 2>&1
    fail 'GitHub CLI login missing (nix develop --command gh auth login).'
end
set -l repo (gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null)
if test -z "$repo"
    fail 'Could not determine GitHub repository from this checkout.'
end
set -l sha (git rev-parse HEAD)
if not gh api "repos/$repo/commits/$sha" --jq .sha >/dev/null 2>&1
    fail 'Commit not found on GitHub. Push the commit first.'
end

if not test -r "$app_id_file" -a -r "$app_key_file"
    fail 'GitHub App not configured. See README: create ~/.config/local-ci/app-id and github-app.pem.'
end
set -l app_id (string trim -- (cat "$app_id_file"))
if not string match -rq '^[0-9]+$' -- "$app_id"
    fail 'Invalid ~/.config/local-ci/app-id: use the numeric GitHub App ID.'
end
set -l token (new_installation_token "$app_id" "$app_key_file" "$repo")
if test -z "$token"
    fail 'Cannot authenticate the app installation. Install it with Checks: write.'
end

umask 077
set -l log_dir (git rev-parse --git-path local-ci)
mkdir -p "$log_dir"; or fail 'Could not create local log directory.'
set -l stamp (date -u +%Y%m%dT%H%M%SZ)
set -l started (date -u +%Y-%m-%dT%H:%M:%SZ)
set -l start_seconds (date +%s)
set -l log "$log_dir/$sha-$stamp.log"
set -l excerpt "$log_dir/$sha-$stamp.excerpt.txt"
set -l report "$log_dir/$sha-$stamp.report.md"
set -l create_payload "$log_dir/$sha-$stamp.create.json"
set -l update_payload "$log_dir/$sha-$stamp.update.json"

jq -n --arg name "$check_name" --arg sha "$sha" --arg started "$started" \
    '{name:$name,head_sha:$sha,status:"in_progress",started_at:$started}' > "$create_payload"

# Keep the App token out of the environment of the actual workflow.
set -lx GH_TOKEN "$token"
set -l check_id (gh api --method POST "repos/$repo/check-runs" \
    --input "$create_payload" --jq .id 2>/dev/null)
set -e GH_TOKEN
set -e token
if not string match -rq '^[0-9]+$' -- "$check_id"
    fail 'Could not create a native Check Run (confirm Checks: write).'
end

echo "Running $workflow locally for $repo @ $sha"
echo "GitHub Check Run: $check_name (#$check_id)"
echo "Full local log: $log"

wrkflw validate "$workflow" 2>&1 | tee "$log"
set -l ci_exit $pipestatus[1]
if test $ci_exit -eq 0
    wrkflw --verbose run --runtime emulation "$workflow" 2>&1 | tee -a "$log"
    set ci_exit $pipestatus[1]
end

set -l conclusion failure
set -l label FAILED
if test $ci_exit -eq 0
    set conclusion success
    set label PASSED
end
set -l finished (date -u +%Y-%m-%dT%H:%M:%SZ)
set -l duration (math (date +%s) - $start_seconds)

# Publish bounded best-effort-redacted diagnostics, not the raw transcript.
# Do not run this on secret-bearing workflows without reviewing this policy.
tail -n 120 "$log" | sed -E \
    -e '/-----BEGIN [A-Z ]*PRIVATE KEY-----/,/-----END [A-Z ]*PRIVATE KEY-----/c\[private key omitted]' \
    -e 's/(gh[pousr]_[A-Za-z0-9_]{16,}|github_pat_[A-Za-z0-9_]{16,}|AKIA[A-Z0-9]{16})/[REDACTED_TOKEN]/g' \
    -e 's/(Bearer[[:space:]]+)[A-Za-z0-9._-]+/\1[REDACTED]/Ig' \
    -e 's#(https?://)[^:/[:space:]]+:[^@[:space:]]+@#\1[REDACTED]@#g' \
    -e 's#(/home/)[^/[:space:]]+#\1[user]#g' \
    -e 's/((TOKEN|PASSWORD|SECRET|API_KEY|PRIVATE_KEY)[[:space:]]*[:=][[:space:]]*)[^[:space:]]+/\1[REDACTED]/Ig' \
    -e 's/~~~/~ ~ ~/g' | head -c 28000 > "$excerpt"

printf '### Local CI: %s\n\n' "$label" > "$report"
printf '%s\n' \
    "- Repository: $repo" \
    "- Commit: $sha" \
    "- Workflow: $workflow" \
    '- Runtime: wrkflw host emulation (no containers)' \
    "- Started (UTC): $started" \
    "- Finished (UTC): $finished" \
    "- Duration: $duration seconds" \
    "- Exit code: $ci_exit" \
    '' \
    'Local CI diagnostics, not a native hosted Actions transcript.' \
    'The complete log remains in .git/local-ci/ on this computer.' \
    '' \
    '#### Diagnostic excerpt (last 120 lines, best-effort redacted)' \
    '' \
    '~~~text' >> "$report"
cat "$excerpt" >> "$report"
printf '\n~~~\n' >> "$report"

set -l summary "Local workflow $label; exit $ci_exit; $duration seconds; SHA $sha. Full logs retained locally."
jq -n --arg conclusion "$conclusion" --arg completed "$finished" \
    --arg title "Local CI $label" --arg summary "$summary" --rawfile text "$report" \
    '{status:"completed",conclusion:$conclusion,completed_at:$completed,output:{title:$title,summary:$summary,text:$text}}' > "$update_payload"

# A job may run longer than the 1-hour installation-token lifetime.
set -l final_token (new_installation_token "$app_id" "$app_key_file" "$repo")
if test -z "$final_token"
    echo 'ERROR: CI finished, but app authentication failed before finalizing the check.' >&2
    exit 1
end
set -lx GH_TOKEN "$final_token"
set -l check_url (gh api --method PATCH "repos/$repo/check-runs/$check_id" \
    --input "$update_payload" --jq .html_url 2>/dev/null)
set -l publish_exit $status
set -e GH_TOKEN
set -e final_token
if test $publish_exit -ne 0 -o -z "$check_url"
    echo 'ERROR: CI finished, but the native Check Run could not be finalized.' >&2
    exit 1
end
printf 'Published GitHub Check: %s (%s)\n' "$check_name" "$conclusion"
printf 'Check details: %s\n' "$check_url"
exit $ci_exit
