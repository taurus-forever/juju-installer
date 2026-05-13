# Error propagation fix: stop the 90-second dead wait after relay_progress failure

**Date**: 2026-05-13
**Status**: Draft

## Goal

When `relay_progress` in `sbin/juju` fails (service script crashed, socket
unreachable, EOF without terminator), the wrapper currently prints an
actionable error message, then silently advances into `wait_for_snap`,
which polls for `/snap/bin/juju` for up to **90 seconds** before reporting
"Juju snap installation timed out." The user sees the relay's ERROR line,
then stares at nothing for a minute and a half.

Make the wrapper exit promptly (under one second) after `relay_progress`
fails, so the user can act on the error they just read instead of waiting
for an unrelated timeout.

## Current state

`sbin/juju` has **no** `set -e`. The three trigger call sites are:

```
sbin/juju:249  trigger_k8s_service
sbin/juju:250  wait_for_snap
sbin/juju:255  trigger_lxd_service
sbin/juju:256  wait_for_snap
sbin/juju:261  trigger_snap_service
sbin/juju:262  wait_for_snap
```

`trigger_*_service` is a one-line wrapper around `relay_progress`. When
`relay_progress`'s python helper hits a connect failure, EOF without
terminator, or any other failure path, the python `sys.exit(1)` propagates
through the function's return — but the call site discards that exit code
and proceeds to `wait_for_snap` regardless. `wait_for_snap` loops for 90
iterations of `sleep 1` before printing its own (now-irrelevant) timeout
error.

The progress-streaming protocol spec at
`docs/superpowers/specs/2026-05-13-progress-streaming-protocol-design.md`
line 224 incorrectly claims:

> `set -e` in `sbin/juju` ensures the wrapper exits if `relay_progress`
> returns non-zero.

This was wrong at spec time and remains wrong post-merge.

## Goals

- Wrapper exits promptly (under 1 second in practice; <10 s wall-clock
  budget in tests) when `relay_progress` returns non-zero.
- Preserve the project's "no `set -e`" invariant in `sbin/juju` (several
  helpers like `has_k8s_cloud`, `has_model` intentionally return non-zero
  when the answer is "no").
- Correct the spec inline so future readers learning the protocol from the
  spec are not misled.
- Regression-test the prompt-exit behavior with a wall-clock assertion so a
  future re-introduction of the dead wait fails the suite.

## Non-goals

- Enabling `set -e` globally in `sbin/juju`. Would surface `has_*` helpers
  and `grep -q` pipes as fatal, requiring an audit of every command.
- Changing `wait_for_snap` itself. It is correct when reached on the success
  path; the bug was only the missing error propagation before it.
- Changing the 1-second `sleep` cadence inside `wait_for_snap`. Out of
  scope for this fix.
- Touching the `sleep 0.1` in `tests/test_wrapper.sh:764`. GNU sleep on
  Ubuntu CI accepts fractional seconds; not a real portability problem.

## Design

### Wrapper change — `sbin/juju`

Three call sites change. Each `trigger_X_service` is appended with
`|| exit 1`:

```sh
    if [ "$substrate" = "k8s" ]; then
        confirm_install "Would you like to install Juju and Canonical K8s snaps now (Y/n)?"
        show_progress "[1/9] Preparing Juju environment (this may take a few minutes)..."
        trigger_k8s_service || exit 1
        wait_for_snap
        do_bootstrap_k8s
    else
        confirm_install "Would you like to install Juju and LXD snaps now (Y/n)?"
        show_progress "[1/5] Preparing Juju environment (this may take a few minutes)..."
        trigger_lxd_service || exit 1
        wait_for_snap
        do_bootstrap_lxd
    fi
else
    confirm_install "Would you like to install Juju snap now (Y/n)?"
    trigger_snap_service || exit 1
    wait_for_snap
fi
```

Why per-site `|| exit 1` rather than `set -e`:
- Local and visible at the call site (matches "scripts are the
  documentation").
- Doesn't change semantics for any other command in the script.
- Three lines added; no audit of unrelated helpers needed.

### Python helper — relay_progress

`s.send(b"i")` becomes `s.sendall(b"i")` (line 105). For a single byte on a
Unix domain stream socket with available buffer space, `send` is guaranteed
to write the byte and `sendall` adds nothing — but `sendall` is the
idiomatic form for "I want all of these bytes written," and is correct if
the payload ever grows. One-character change, no behavior change.

### Spec correction — progress-streaming-protocol-design.md line 224

Replace:

> `set -e` in `sbin/juju` ensures the wrapper exits if `relay_progress`
> returns non-zero.

with:

> Each `trigger_*_service` call site uses `|| exit 1` to propagate
> `relay_progress` failure to the wrapper, so the user does not stare at
> a silent `wait_for_snap` loop for 90 seconds after an "exited
> unexpectedly" message.

### Regression test — tests/test_wrapper.sh

Add one test that exercises the EOF-without-terminator path against the
real wrapper and asserts both non-zero exit *and* a wall-clock budget:

```sh
test_relay_failure_exits_promptly() {
    setup
    SCRIPT="${TEST_DIR}/script"
    printf '__CLOSE__\n' > "$SCRIPT"
    start_mock_service "${FAKE_K8S_SOCKET}" "$SCRIPT"
    patch_wrapper_with_real_relay
    start=$(date +%s)
    run_patched deploy postgresql-k8s --trust
    elapsed=$(( $(date +%s) - start ))
    result=0
    [ "$LAST_RC" -ne 0 ] || { echo "  ASSERT FAILED: expected non-zero exit"; result=1; }
    [ "$elapsed" -lt 10 ] || { echo "  ASSERT FAILED: relay failure took ${elapsed}s, expected <10s"; result=1; }
    stop_mock_service
    teardown
    return $result
}
run_proto_test "relay: failure exits in <10s (no dead wait)" test_relay_failure_exits_promptly
```

10-second budget is generous (actual fast-fail is <1 s) but tolerates CI
variance. Any re-introduction of the 90-second dead wait fails this test.

The existing `test_relay_eof_without_terminator` continues to assert the
ERROR text on stderr; this new test asserts the *timing* contract that
test was missing.

### Out-of-scope items considered

- `sleep 0.1` in `tests/test_wrapper.sh:764`. GNU sleep accepts fractional
  seconds; Ubuntu CI uses GNU coreutils. Strict POSIX would require
  `sleep 1`, but that would slow the mock-ready poll cap from 5 s to 50 s
  for no real benefit. Leaving as-is.

## Testing

After the change, `sh tests/run_all.sh` should show 71/71 passing (one new
test added to the 70 currently passing). Existing
`test_relay_eof_without_terminator`, `test_relay_socket_missing`, and
`test_service_error_line_relayed` still pass; their stderr-content
assertions are unaffected by the new `|| exit 1`.

## Migration notes

This is a pure shell-and-docs change shipped together. Anyone running the
0.2.1 package upgrades to a version with prompt error propagation; nothing
is broken on the old version, just slower to fail.

Changelog: bump to **0.2.2** for the release, or append a bullet to a
new 0.2.2 stanza in `debian/changelog`. Defer the version-bump decision
to implementation time; the fix is mechanically the same either way.

## Open questions

None at spec time. The four review items have explicit decisions; the only
deferred item is the version-bump preference.
