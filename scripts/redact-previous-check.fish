#!/usr/bin/env fish

# One-time privacy remediation for the first verbose public Check Run.
# Updates ONLY the known Local Nix CI check; no commits or comments.
set -l repo sguzman/local-ci-testing
set -l check_id 137879846223
set -l expected_sha 4f38ef0a6e69d3cbd00acbb66f7d8b39bbbdfc3f
set -l app_id_file "$HOME/.config/local-ci/app-id"
set -l app_key_file "$HOME/.config/local-ci/github-app.pem"

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

if not test -r "$app_id_file" -a -r "$app_key_file"
    echo 'Missing local GitHub App credentials.' >&2
    exit 1
end
set -l app_id (string trim -- (cat "$app_id_file"))
if not string match -rq '^[0-9]+$' -- "$app_id"
    echo 'Invalid GitHub App ID.' >&2
    exit 1
end

set -l token (new_installation_token "$app_id" "$app_key_file" "$repo")
if test -z "$token"
    echo 'Failed to authenticate the GitHub App installation.' >&2
    exit 1
end

set -lx GH_TOKEN "$token"
set -l actual_sha (gh api "repos/$repo/check-runs/$check_id" --jq .head_sha 2>/dev/null)
if test "$actual_sha" != "$expected_sha"
    echo 'Refusing to update a check on an unexpected commit.' >&2
    set -e GH_TOKEN
    exit 1
end

set -l safe_text 'Diagnostic transcript removed because it included local environment metadata. CI passed; full original transcript is only available on the local machine.'
set -l payload (jq -cn --arg text "$safe_text" \
    '{output:{title:"Local CI passed",summary:"CI passed locally using wrkflw and Nix. Public diagnostic output was removed for privacy.",text:$text}}')
set -l result (printf '%s' "$payload" | gh api --method PATCH \
    "repos/$repo/check-runs/$check_id" --input - --jq .id 2>/dev/null)
if test "$result" != "$check_id"
    echo 'GitHub did not confirm the Check Run update.' >&2
    set -e GH_TOKEN
    exit 1
end

# Read it back so a successful HTTP request is not mistaken for redaction.
set -l published_text (gh api "repos/$repo/check-runs/$check_id" \
    --jq '.output.text' 2>/dev/null)
set -e GH_TOKEN
set -e token
if test "$published_text" != "$safe_text"
    echo 'WARNING: Could not verify the public report was replaced.' >&2
    exit 1
end

echo 'Redacted the previous public Check Run output and verified the replacement.'
echo "https://github.com/$repo/runs/$check_id"
