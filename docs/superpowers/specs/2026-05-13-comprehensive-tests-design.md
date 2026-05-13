# Comprehensive test suite for juju-installer

**Date**: 2026-05-13
**Status**: Draft

## Goal

Expand test coverage from 24 wrapper-only tests to a comprehensive suite
covering the wrapper, all three service scripts, and packaging/systemd
structural validation. Use the existing mock pattern (sed-patching, temp
directories, assert helpers) with zero new dependencies.

## Current state

- `tests/test_wrapper.sh`: 24 tests for `sbin/juju` wrapper logic
- `share/*` service scripts: 0 tests
- `systemd/` unit files: 0 structural validation
- `debian/` packaging: 0 validation
- CI runs `sh tests/test_wrapper.sh` only

## Coverage gaps identified

### Wrapper (`sbin/juju`)

| Gap | Risk |
|---|---|
| `deploy` with no charm name | Crash or undefined behavior |
| Charm name with `ch:` prefix | Misdetection of substrate |
| Local path charm (`./local-charm`) | Misdetection of substrate |
| Exit code propagation from real juju | Wrapper swallows errors silently |
| `wait_for_snap` timeout path | Infinite hang or unclear error |
| `do_bootstrap_lxd` step-skip logic | Re-run after partial setup fails |
| `do_bootstrap_k8s` missing kubeconfig | Unclear error message |
| `do_bootstrap_k8s` kubeconfig backup | Overwrites existing kubeconfig |
| `do_bootstrap_k8s` step-skip logic | Re-run after partial setup fails |
| Multiple combined flags | Flag parsing breaks with complex args |

### Service scripts (`share/*`)

All three service scripts have zero tests. They run as root under systemd
and are the most dangerous code in the project.

### Infrastructure

No validation that systemd units parse correctly, socket paths match the
wrapper code, or `debian/install` lists every shipped file.

## File layout

```
tests/
  run_all.sh            # NEW: runner that aggregates all test files
  test_wrapper.sh       # EXISTING: expanded with 12 new tests
  test_services.sh      # NEW: 15 tests for service scripts
  test_packaging.sh     # NEW: 7 structural validation tests
```

Total: 24 existing + 12 new wrapper + 15 service + 7 packaging = 58 tests.

## Test file 1: expanded test_wrapper.sh

12 new tests using the existing `setup/patch_wrapper/run_patched/assert`
pattern. No changes to the test infrastructure.

### Edge case tests

**deploy with no charm name**:
Run `deploy` with no positional argument. Wrapper should not crash.
`extract_charm_name` returns empty, `detect_substrate` defaults to `lxd`.

**deploy ch:postgresql-k8s**:
Charm name with `ch:` Charmhub prefix. `extract_charm_name` should return
`ch:postgresql-k8s`. `detect_substrate` should detect the `-k8s` suffix.

**deploy ./local-charm**:
Local path starting with `./`. Should fall through to LXD substrate (no
`-k8s` suffix).

**Multiple combined flags**:
`deploy --channel 14/edge --num-units 3 postgresql-k8s --trust`. Validates
that all value-flags are skipped correctly.

### Exit code propagation

Make `mock-juju` exit with code 42. Verify the wrapper propagates the same
exit code to the caller. Test both the passthrough path (`exec`) and the
post-bootstrap path (`"$SNAP_BIN" "$@"`).

### Bootstrap idempotency tests

Un-stub `do_bootstrap_lxd` and `do_bootstrap_k8s` for these tests. Instead,
stub the individual check functions and the `juju` binary.

**LXD: skip existing controller**:
Set `MOCK_HAS_LXD_CONTROLLER=1`. Verify bootstrap step is skipped, model
creation still runs.

**LXD: skip existing model**:
Set `MOCK_HAS_MODEL=1`. Verify add-model step is skipped.

**K8s: missing kubeconfig**:
Do not create `/run/juju-installer-k8s-kubeconfig`. Verify error message
about missing kubeconfig.

**K8s: kubeconfig backup**:
Create an existing `~/.kube/config` in the test directory. Verify it gets
copied to `~/.kube/config.bak`.

**K8s: skip existing cloud**:
Set `MOCK_HAS_K8S_CLOUD=1`. Verify `add-k8s` step is skipped.

**K8s: skip existing controller**:
Set `MOCK_HAS_K8S_CONTROLLER=1`. Verify bootstrap step is skipped.

### wait_for_snap timeout

Patch `wait_for_snap` to use a 1-second timeout instead of 90 seconds.
Never create the fake snap binary. Verify the wrapper exits with an error
message about timeout.

## Test file 2: test_services.sh

15 tests for the three service scripts. Uses the same mock infrastructure
pattern as `test_wrapper.sh`.

### Mock strategy

- Create fake `snap`, `lxd`, `k8s`, `lxc` binaries in a temp `PATH`
  directory. Each fake logs its invocation to a file and exits 0.
- Sed-patch service scripts to use temp paths instead of `/snap/bin/*`.
- Pipe a mode byte (`echo i`) to stdin to simulate the socket protocol.
- Check stdout for the completion signal (`1`).
- Check the invocation log to verify which commands were called.

### Snap service tests (3)

**snap_full_install**: Juju snap not installed. Verify `snap install juju`
is called. Verify stdout contains `1` (completion signal).

**snap_already_installed**: Create fake `/snap/bin/juju`. Verify `snap
install` is not called. Verify completion signal.

**snap_signal_protocol**: Verify exactly one byte (`1`) is written to
stdout (the socket expects this).

### LXD service tests (5)

**lxd_full_install**: Nothing installed. Verify: `snap install juju` called,
lxd-installer socket triggered, `lxd init --auto` called, completion signal
sent.

**lxd_snap_exists**: LXD snap already present. Verify LXD install step
skipped.

**lxd_already_initialized**: Fake `lxc storage list` returns `default`.
Verify `lxd init --auto` skipped.

**lxd_install_timeout**: Fake LXD binary never appears. Verify error message
and non-zero exit.

**lxd_idempotent**: Everything already set up. Verify script is a no-op
that sends completion signal.

### K8s service tests (7)

**k8s_full_install**: Nothing installed. Verify all 6 steps execute in order:
install juju, install k8s, bootstrap, wait-ready, enable storage, export
kubeconfig.

**k8s_snap_exists**: K8s snap already present. Verify install step skipped.

**k8s_already_bootstrapped**: Fake `k8s status` succeeds. Verify bootstrap
step skipped.

**k8s_not_ready_timeout**: Fake `k8s status --wait-ready` always fails.
Verify error message and non-zero exit.

**k8s_storage_already_enabled**: Fake `k8s status` output includes
`local-storage.*enabled`. Verify enable step skipped.

**k8s_kubeconfig_permissions**: Verify exported file has mode 0640 and
group `lxd`. (Group check may need to be skipped if `lxd` group does not
exist on the CI runner; test the chmod call instead.)

**k8s_idempotent**: Everything already set up. Verify only kubeconfig
export runs, completion signal sent.

## Test file 3: test_packaging.sh

7 structural validation tests. No mocking needed; these are static checks
on the repository files.

### Systemd unit validation (4)

**systemd_units_parse**: If `systemd-analyze` is available, run
`systemd-analyze verify` on each unit file. Skip gracefully if the tool
is not installed.

**socket_paths_match_code**: Extract socket paths from `sbin/juju`
(`/run/juju-installer-*.socket`) and from `systemd/*.socket`
(`ListenStream=`). Verify they match.

**socket_group_lxd**: Verify every `.socket` file contains
`SocketGroup=lxd`.

**socket_accept_true**: Verify every `.socket` file contains `Accept=true`.

### Debian packaging validation (3)

**install_covers_all_files**: For every file in `sbin/`, `share/`,
`systemd/`, verify a corresponding entry exists in `debian/install`.

**no_stale_install_entries**: For every source path listed in
`debian/install`, verify the file exists on disk.

**service_execstart_paths**: Extract `ExecStart=` paths from `.service`
files. Verify each path's source file exists and is listed in
`debian/install`.

## Test runner: run_all.sh

Simple POSIX sh script that:
1. Finds all `tests/test_*.sh` files
2. Runs each with `sh`
3. Aggregates pass/fail counts from the `=== Results ===` line
4. Prints a final summary
5. Exits non-zero if any file had failures

Each test file remains independently runnable via `sh tests/test_*.sh`.

## CI integration

Update `.github/workflows/_test.yml`:

```yaml
- run: sh tests/run_all.sh
```

No other workflow changes needed. The lint workflow already covers
shellcheck for `sbin/juju` and `share/*`. The new test files should also
be shellcheck-clean, so add `tests/*` to the lint scope.

Update `.github/workflows/lint.yml`:

```yaml
- run: shellcheck sbin/juju share/* tests/*.sh
```

## Design principles

- **Zero new dependencies**: same POSIX sh, same mock pattern, same assert
  helpers.
- **Each test file is self-contained**: copy/adapt the helper functions
  (`setup`, `teardown`, `report`, `assert_*`) into each new file. Small
  duplication is preferable to a shared test library that adds coupling.
- **Tests must run without root**: all service script tests use mocked
  binaries and temp directories.
- **Tests must run on any Ubuntu release**: no version-specific behavior.
- **Consistent output format**: every test file ends with
  `=== Results: N/M passed, F failed ===` so the runner can aggregate.

## Out of scope

- Integration tests that require real snaps, LXD, or K8s (too slow, need
  privileged VMs)
- Code coverage tools (no shell coverage tooling worth the dependency)
- Test frameworks (BATS, shunit2) — zero new dependencies
- Refactoring the wrapper to make it more testable — test what exists
