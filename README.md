# Local CI testing

Tiny Rust program testing **one GitHub Actions workflow** in two places:

- **GitHub:** `.github/workflows/ci.yml` runs on a hosted runner and installs Nix.
- **Locally:** `wrkflw` runs the **same workflow YAML** in host emulation mode, without Docker or Podman.

**Everything is defined in Nix.** The pinned `flake.lock` selects nixpkgs, which supplies the Rust compiler, Cargo, Clippy, rustfmt, and `wrkflw`. The flake offers two dev shells:

- `nix develop` (default): Rust CI tools **plus `wrkflw`** for local workflow execution.
- `nix develop .#ci`: just the Rust CI tools, used by the GitHub Actions job and the commands it runs under `wrkflw`.

This avoids an external `nix profile install`, and GitHub's runner doesn't spend time provisioning a workflow executor it never calls.

## Run locally (fish / Linux)

Prerequisites: Nix with `nix-command` and `flakes` enabled, and Git.

For a new checkout:

```fish
git clone https://github.com/sguzman/local-ci-testing.git
cd local-ci-testing
nix develop --command wrkflw validate
nix develop --command wrkflw run --runtime emulation .github/workflows/ci.yml
```

For an existing checkout, first `git pull --ff-only` from the repository directory.

`nix develop --command wrkflw ...` supplies `wrkflw` on demand using this repository's locked Nix environment. Nothing needs to be installed into your user profile. Emulation runs shell commands with **your user permissions**, so only run trusted workflows.

To run the Nix-native checks directly:

```fish
nix flake check --print-build-logs
nix develop .#ci --command cargo test --all-targets --locked
nix build
./result/bin/local-ci-testing
```

Expect: `Hello from local-ci-testing!`

## What this experiment proves

Passing both GitHub Actions and local wrkflw is evidence that workflow steps and a pinned Nix environment can be reused. It does **not** guarantee full GitHub-runner equivalence: OS details, action implementations, credentials, and services can differ. Review wrkflw's verdict for partially checked steps. A local run does not create a GitHub Actions run or upload commit statuses by itself; that requires a separate publishing step/API call.

The **GitHub Actions workflow** is the source of truth for CI jobs; the **Nix flake and lockfile** are the source of truth for development and CI dependencies.
