#!/usr/bin/env fish

# Public CI output is constructed ONLY from fixed labels and numeric status.
# Never interpolate arbitrary workflow stdout/stderr or environment values.
function ci_failed_step --argument-names log_path
    if not test -r "$log_path"
        return 1
    end

    # Explicit allowlist: even if a workflow prints a fake failure line,
    # the public value can only be one of these non-sensitive labels.
    set -l allowed_steps \
        'Check out source' \
        'Install Nix on GitHub-hosted runner' \
        'Show pinned toolchain' \
        'Rustfmt' \
        'Clippy' \
        'Tests' \
        'Smoke test' \
        'Nix package check' \
        'Validate local status publisher syntax' \
        'Validate privacy cleanup script syntax' \
        'Test CI reporting privacy'

    for step in $allowed_steps
        for marker in '  ✘ ' '  ✗ ' '  ✖ ' '  ❌ ' '  × '
            if string match --quiet -- "$marker$step" < "$log_path"
                printf '%s\n' "$step"
                return 0
            end
        end
    end
    return 1
end

function ci_public_output --argument-names exit_code phase duration log_path
    if test "$exit_code" -eq 0
        jq -nc --arg summary "Passed in $duration seconds." \
            '{title:"Local CI passed",summary:$summary}'
        return $status
    end

    set -l failure 'Workflow execution'
    if test "$phase" = validation
        set failure 'Workflow validation'
    else
        set -l failed_step (ci_failed_step "$log_path")
        if test -n "$failed_step"
            set failure "$failed_step"
        end
    end

    # The only dynamic failure name is a literal from the allowlist above.
    # There is NEVER a log excerpt, untrusted error string, or environment dump.
    set -l summary "Failed: $failure · exit $exit_code · $duration seconds."
    set -l detail "Failure: $failure. Exit code: $exit_code. Full diagnostics remain only under .git/local-ci/ on the local machine; no raw logs were uploaded."
    jq -nc --arg summary "$summary" --arg detail "$detail" \
        '{title:"Local CI failed",summary:$summary,text:$detail}'
end
