# Local CI testing

A tiny Rust application that runs the **same GitHub Actions workflow** on GitHub and locally with **Nix + wrkflw**, without Docker.

- Workflow source of truth: `.github/workflows/ci.yml`
- Toolchain: pinned `flake.nix` and `flake.lock`
- Local runner + reporter: `scripts/run-local-ci.fish`
- Local reports: native GitHub Checks API (**no commit comments**)

## One-time GitHub App setup — all current and future personal repositories

Create a **private GitHub App** under your personal account at https://github.com/settings/apps/new.

1. Use a name such as **Local Nix CI**, homepage URL `https://github.com/sguzman/local-ci-testing`, and **Only on this account**. Webhooks and OAuth callback/authentication are not needed for a locally invoked reporter.
2. In **Repository permissions**, enable **Checks: Read and write**. Leave all other permissions disabled; Metadata read is automatic.
3. Create the app. Copy its **numeric App ID** and **Generate a private key** (`.pem`). Keep the private key secret; never upload it to GitHub, chat, or the Nix store.
4. From the app's settings page choose **Install App**, install under `sguzman`, and select **All repositories**. One installation covers existing and future repositories owned by that account. Organization-owned repos need their own installation.
5. Configure the same local credentials for every repository (fish):

```fish
mkdir -p ~/.config/local-ci
printf '%s\n' YOUR_NUMERIC_APP_ID > ~/.config/local-ci/app-id
install -m 600 ~/Downloads/YOUR_DOWNLOADED_KEY.pem ~/.config/local-ci/github-app.pem
```

Replace both placeholders with the actual ID and filename; keep the key file private. The script discovers the installation automatically for each repository and creates short-lived tokens when needed. **No setup or authentication per repository.**

## Run and publish a native GitHub Check

From a clean checkout of an already-pushed commit:

```fish
git pull --ff-only
nix develop --command fish scripts/run-local-ci.fish
```

GitHub CLI (`gh`) must already be authenticated for checkout lookup; if not, run `nix develop --command gh auth login` once. This OAuth login is separate from the GitHub App, whose key is only used to authenticate to the Checks API.

The runner creates an **in progress** Check Run and executes the workflow locally.

- **Success:** GitHub receives only a pass result and duration. No full step list or build output.
- **Failure:** GitHub receives exit code, duration, and the failing step *only if it matches a fixed allowlist of known workflow step names*. Otherwise it reports the failed phase (validation/execution). This is intentionally conservative.
- **Privacy:** GitHub never receives raw log lines, environment variables, error messages, or excerpts. Complete diagnostics remain under `.git/local-ci/` on this machine. Terminal output is similarly minimal; inspect the local log when troubleshooting.

The output construction policy lives in `scripts/ci-report.fish` and has fixture-based privacy regression tests in `scripts/test-ci-report.fish`. The check is not a GitHub-hosted Actions transcript.

**One-time public-report cleanup:** If you ran the old verbose publisher before this change, its public Check Run may already include environment metadata. From this repository run:

```fish
nix develop --command fish scripts/redact-previous-check.fish
```

That command overwrites the known earlier Check Run's public output with a minimal safe summary, and reads it back to verify. It does not revoke a credential, undo past access, or delete any local logs. Avoid uploading secret-bearing logs to public repositories.

The App has minimal permissions: **Checks: write**. The local machine holds the private key, outside the repo. Every invocation mints new short-lived installation credentials, including after builds that take over an hour.

## Run locally without uploading

```fish
nix develop --command wrkflw validate
nix develop --command wrkflw run --runtime emulation .github/workflows/ci.yml
```

## Direct Nix verification

```fish
nix flake check --print-build-logs
nix develop .#ci --command cargo test --all-targets --locked
nix build
./result/bin/local-ci-testing
```

Expected output: `Hello from local-ci-testing!`

Only run trusted workflows using host emulation, since they execute code with your local user's permissions. The host's operating environment is not necessarily identical to GitHub's hosted Ubuntu runner.
