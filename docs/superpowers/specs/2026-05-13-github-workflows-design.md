# GitHub Actions workflows for juju-installer

**Date**: 2026-05-13
**Status**: Draft

## Goal

Add GitHub Actions CI workflows to automate testing and linting. The project
currently has no CI. Tests (`sh tests/test_wrapper.sh`) are pure POSIX sh and
run in under a second with no external dependencies.

## Constraints

- Free GitHub-hosted runners only (`ubuntu-latest`, currently 24.04).
- No paid services, no self-hosted runners.
- Keep workflows minimal, matching the project's design philosophy.

## File layout

```
.github/workflows/
  _test.yml      # reusable workflow: checkout + run tests
  ci.yml         # caller: on PR and push to main
  weekly.yml     # caller: cron Friday 03:42 UTC
  lint.yml       # standalone: shellcheck on PR
```

The `_` prefix on `_test.yml` signals it is called by other workflows, not
triggered directly.

## Workflow 1: _test.yml (reusable)

Triggered by `workflow_call` only. Runs on `ubuntu-latest`.

Steps:
1. `actions/checkout@v4`
2. `sh tests/test_wrapper.sh`

No matrix builds, no caching, no artifacts. The tests are pure shell mocks
that finish instantly.

## Workflow 2: ci.yml (PR and push caller)

Triggers:
- `pull_request` targeting `main`
- `push` to `main` (catches merge breakage)

Single job that calls `_test.yml`.

## Workflow 3: weekly.yml (scheduled caller)

Trigger:
- `schedule: cron '42 3 * * 5'` (every Friday at 03:42 UTC)

Single job that calls `_test.yml`. Ensures tests still pass even without
active development.

## Workflow 4: lint.yml (shellcheck)

Triggers:
- `pull_request` targeting `main`

Standalone workflow (not reusable) because it is a different job type.

Steps:
1. `actions/checkout@v4`
2. `shellcheck sbin/juju share/*`

ShellCheck is pre-installed on GitHub `ubuntu-latest` runners.

Catches POSIX sh violations, bashisms, and common shell scripting errors
before merge.

## Permissions

All workflows use the default `GITHUB_TOKEN` permissions. No secrets, no
write permissions, no external service integrations.

## Runner image

`ubuntu-latest` (currently 24.04). The tests are OS-independent shell mocks.
When GitHub adds Ubuntu 26.04 runners, the workflows will pick it up
automatically via `ubuntu-latest` or can be pinned explicitly.

## Out of scope

- DCO/sign-off checks
- Stale issue/PR cleanup
- Release automation
- Container-based testing
- Self-hosted runners
