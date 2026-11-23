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
source scripts/ci-report.fish; or fail "Could not load safe CI report policy."

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

# Capture diagnostics exclusively in the local Git directory.
# Do not echo arbitrary step output or any log excerpts to GitHub or terminal.
set -l phase validation
wrkflw validate "$workflow" > "$log" 2>&1
set -l ci_exit $status
if test $ci_exit -eq 0
    set phase execution
    wrkflw run --runtime emulation "$workflow" >> "$log" 2>&1
    set ci_exit $status
end

set -l conclusion failure
if test $ci_exit -eq 0
    set conclusion success
end
set -l finished (date -u +%Y-%m-%dT%H:%M:%SZ)
set -l duration (math (date +%s) - $start_seconds)

# Pure allowlisted report: never send raw, filtered, or truncated build output.
set -l public_output (ci_public_output "$ci_exit" "$phase" "$duration" "$log")
if test -z "$public_output"
    fail 'Could not construct the privacy-safe GitHub report.'
end
jq -n --arg conclusion "$conclusion" --arg completed "$finished" \
    --argjson output "$public_output" \
    '{status:"completed",conclusion:$conclusion,completed_at:$completed,output:$output}' > "$update_payload"

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
printf '%s\n' "$public_output" | jq -r '.summary'
printf 'Check details: %s\n' "$check_url"
exit $ci_exit
