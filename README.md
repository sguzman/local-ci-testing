# Local CI testing

Tiny Rust program testing **one GitHub Actions workflow** in two places:

- **GitHub:** `.github/workflows/ci.yml` runs on a hosted runner and installs Nix.
- **Locally:** `wrkflw` runs the **same workflow YAML** in host emulation mode, without Docker or Podman.

**Everything is provisioned through Nix.** The pinned `flake.lock` selects nixpkgs, which supplies the Rust toolchain, `wrkflw`, `fish`, and the GitHub CLI (`gh`). The flake offers two dev shells:

- `nix develop` (default): Rust CI tools, `wrkflw`, `fish`, and `gh` for local CI and status reporting.
- `nix develop .#ci`: only the tools used in the GitHub workflow, including `fish` for syntax checking.

## Local run and publish to GitHub (fish / Linux)

Requires Nix with `nix-command` and `flakes` enabled, and Git. No separate installations of `wrkflw` or `gh` are needed.

```fish
git clone https://github.com/sguzman/local-ci-testing.git
cd local-ci-testing
nix develop --command gh auth login
nix develop --command fish scripts/run-local-ci.fish
```

If already cloned and authenticated, use:

```fish
git pull --ff-only
nix develop --command fish scripts/run-local-ci.fish
```

**The wrapper performs all of the following:**

1. Refuses to publish a status if the working tree is dirty.
2. Checks that `gh` is authenticated and that the current commit exists on GitHub.
3. Validates `.github/workflows/ci.yml` using `wrkflw`.
4. Runs that workflow using `wrkflw --runtime emulation` (no Docker).
5. Publishes a `success` or `failure` commit status under **`local-ci/wrkflw-host`** using GitHub's REST API.

The status is attached to the exact commit tested and is visible with its other checks. It is **not** a hosted GitHub Actions run and cannot replace GitHub's native run history. Publishing uses GitHub's **Commit statuses: write** permission on the target repository. `gh auth login` is interactive and may need refreshed scopes depending on the credentials you already have.

The status description specifically says **host-emulation**: this is evidence of a local pass, **not** proof that every step executed exactly as on GitHub. `wrkflw` may skip unsupported actions. Inspect its output before treating a pass as equivalent to a hosted run.

## Just run locally, without publishing

```fish
nix develop --command wrkflw validate
nix develop --command wrkflw run --runtime emulation .github/workflows/ci.yml
```

To run the Nix-native checks directly:

```fish
nix flake check --print-build-logs
nix develop .#ci --command cargo test --all-targets --locked
nix build
./result/bin/local-ci-testing
```

Expect: `Hello from local-ci-testing!`

## What this experiment proves

The GitHub Actions workflow is the **source of truth for CI jobs**; the Nix flake is the **source of truth for dependencies**. The local publisher adds commit-status reporting without consuming GitHub-hosted Actions compute minutes. It does not turn the local run into a native GitHub Actions run.

For safety, the publisher is a **manual opt-in command**, not an automatic push hook. Run host-emulated workflows only from trusted repositories: their steps can access your machine and user credentials.
