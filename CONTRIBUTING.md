# Contributing to LocalPorts

Thanks for contributing.

## Before You Start
- Open an issue first for significant changes.
- Keep changes focused and small.
- Prefer follow-up PRs over one large PR.

## Local Setup
```bash
git clone <your-fork-or-repo-url>
cd LocalPorts
xcodebuild -project LocalPorts.xcodeproj -scheme LocalPorts -configuration Debug -derivedDataPath .build build
./scripts/ci-smoke.sh
```

## Branch and Commit Guidelines
- Branch naming:
  - `feat/<short-topic>`
  - `fix/<short-topic>`
  - `docs/<short-topic>`
- Commit style (recommended):
  - `feat: ...`
  - `fix: ...`
  - `docs: ...`
  - `chore: ...`

## Pull Request Checklist
- CI passes (`.github/workflows/ci.yml`).
- No machine-specific paths/secrets added.
- README/docs updated if behavior changed.
- Changes tested manually for affected flows.
- PR description includes:
  - What changed
  - Why
  - How it was tested

## Scope Rules
- Avoid unrelated refactors in bugfix PRs.
- Don’t rename/move many files unless required.
- Preserve existing UX patterns unless PR explicitly changes UX.
