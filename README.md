# Local CI testing

Minimal Rust example demonstrating **one GitHub Actions workflow** with a pinned Nix environment, executed on GitHub or locally through wrkflw (no Docker).

- **Workflow source of truth:** `.github/workflows/ci.yml`
- **Dependencies source of truth:** `flake.nix` and `flake.lock`
- **Local runner:** `wrkflw`, provisioned by the default Nix development shell
- **Results publisher:** `scripts/run-local-ci.fish`, using GitHub CLI (`gh`) from that same shell

## Run locally and publish results

After cloning the repository and authenticating `gh` once:

```fish
git pull --ff-only
nix develop --command fish scripts/run-local-ci.fish
```

If not already authenticated:

```fish
nix develop --command gh auth login
```

The runner refuses dirty working trees and verifies that HEAD is already on GitHub. It validates and runs the actual workflow in host-emulation mode. It records full output locally under `.git/local-ci/`, then publishes:

1. A Markdown **commit comment** with workflow, commit, timestamps, runtime, exit code, and the **last 120 lines** of redacted output.
2. A commit status named `local-ci/wrkflw-host`, with the **Details** link pointing to that report.

The runner reports failures as failures (including a nonzero shell exit code) and reports the failure details automatically. Reports are attached to commits, **not added as commits**. Every run creates another report comment; there are no modifications to source code when CI runs.

**Permissions:** Your existing `gh` authentication normally suffices. The token must have permission to write commit statuses and repository contents (for commit comments). You do **not** need to create a custom GitHub App.

**Security:** Only a bounded diagnostic excerpt is published, not raw complete logs. Basic credential patterns and home usernames are filtered, but automated redaction can never guarantee secrecy. On a public repository, the comment is **public**. Avoid running secrets-bearing jobs through this reporting method. Full logs remain local. This is not equivalent to GitHub-hosted Actions job logs or native Checks API annotations.

## Run without reporting

```fish
nix develop --command wrkflw validate
nix develop --command wrkflw run --runtime emulation .github/workflows/ci.yml
```

## Run Nix checks directly

```fish
nix flake check --print-build-logs
nix develop .#ci --command cargo test --all-targets --locked
nix build
./result/bin/local-ci-testing
```

Expected output: `Hello from local-ci-testing!`

The runner is deliberately manual rather than a push hook. Host-emulated workflows execute code with your user's permissions; only run trusted workflow definitions.
