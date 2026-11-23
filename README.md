# Local CI testing

Tiny Rust program that exists to exercise **one GitHub Actions workflow** in two places:

- **GitHub:** `.github/workflows/ci.yml` runs on GitHub's Ubuntu runner and installs Nix.
- **Locally:** `wrkflw` runs that **same workflow YAML** in host emulation mode (no Docker/Podman); it uses Nix already installed on your machine.

`flake.nix` defines the Rust toolchain; `flake.lock` pins nixpkgs. No JavaScript, Docker images, CI-specific secondary scripts, or external Rust crates.

## Run locally (fish / Linux)

Prerequisites: Nix with `nix-command` and `flakes` enabled, Git, and `wrkflw`. You can install the latter with `nix profile install nixpkgs#wrkflw` if it isn't already present.

```fish
git clone https://github.com/sguzman/local-ci-testing.git
cd local-ci-testing
wrkflw validate
wrkflw run --runtime emulation .github/workflows/ci.yml
```

This invokes the exact steps defined in GitHub Actions: Rust version, formatting, Clippy, tests, smoke test, and the Nix package check. The Nix-install action is deliberately guarded by `runner.environment == 'github-hosted'`; wrkflw sets that value to `local`. Emulation executes the workflow's shell commands with **your user permissions**, so use trusted workflows only.

To run the Nix-native checks directly, without wrkflw:

```fish
nix flake check --print-build-logs
nix develop --command cargo test --all-targets --locked
nix build
./result/bin/local-ci-testing
```

Expect: `Hello from local-ci-testing!`

## What this experiment proves

Passing both GitHub Actions and local wrkflw is evidence that the workflow steps and pinned Nix environment can be reused. It does **not** guarantee full GitHub-runner equivalence: host OS details, action implementations, credentials, and services can differ. Review wrkflw's verdict for any partially checked steps. The local runner does not create a GitHub Actions run or upload commit statuses by itself; that requires a separate publishing step/API call.

The GitHub Actions workflow is the **single source of truth for CI jobs**; the flake is the **single source of truth for dependencies**.
