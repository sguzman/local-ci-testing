#!/usr/bin/env fish

source scripts/ci-report.fish; or exit 1

set -l sample (mktemp); or exit 1
# Synthetic secret proves workflow log content never enters the public result.
printf '%s\n' \
    'DO_NOT_UPLOAD_THIS_SECRET=simulated-secret-value' \
    '  ✘ Clippy' > "$sample"

set -l passed (ci_public_output 0 execution 8 "$sample")
printf '%s\n' "$passed" | jq -e '
    .title == "Local CI passed" and
    .summary == "Passed in 8 seconds." and
    (has("text") | not) and
    (tostring | contains("DO_NOT_UPLOAD_THIS_SECRET") | not)
' >/dev/null
or exit 1

set -l failed (ci_public_output 7 execution 8 "$sample")
printf '%s\n' "$failed" | jq -e '
    .title == "Local CI failed" and
    (.summary | contains("Clippy") and contains("exit 7")) and
    (.text | contains(".git/local-ci/")) and
    (tostring | contains("DO_NOT_UPLOAD_THIS_SECRET") | not)
' >/dev/null
or exit 1

printf '%s\n' 'DO_NOT_UPLOAD_THIS_SECRET=simulated-secret-value' > "$sample"
set -l unknown (ci_public_output 2 execution 5 "$sample")
printf '%s\n' "$unknown" | jq -e '
    (.summary | contains("Workflow execution")) and
    (tostring | contains("DO_NOT_UPLOAD_THIS_SECRET") | not)
' >/dev/null
or exit 1

set -l validation (ci_public_output 1 validation 1 "$sample")
printf '%s\n' "$validation" | jq -e '
    (.summary | contains("Workflow validation")) and
    (tostring | contains("DO_NOT_UPLOAD_THIS_SECRET") | not)
' >/dev/null
or exit 1

rm -f "$sample"
echo 'CI reporting privacy tests passed.'
