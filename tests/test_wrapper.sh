#!/bin/sh
# Unit tests for /sbin/juju wrapper script (PoC2).
# Run: sh tests/test_wrapper.sh
#
# These tests mock the snap binary, sockets, and /proc/self/cgroup
# to exercise wrapper logic without real snaps or systemd.
set -eu

WRAPPER="$(cd "$(dirname "$0")/.." && pwd)/sbin/juju"
PASS=0
FAIL=0
TOTAL=0

setup() {
    TEST_DIR=$(mktemp -d)
    FAKE_SNAP_BIN="${TEST_DIR}/snap/bin/juju"
    FAKE_SNAP_SOCKET="${TEST_DIR}/run/juju-installer-snap.socket"
    FAKE_LXD_SOCKET="${TEST_DIR}/run/juju-installer-lxd.socket"
    FAKE_K8S_SOCKET="${TEST_DIR}/run/juju-installer-k8s.socket"
    FAKE_CGROUP="${TEST_DIR}/proc_self_cgroup"

    mkdir -p "${TEST_DIR}/snap/bin" "${TEST_DIR}/run"

    echo "0::/user.slice/user-1000.slice/session-1.scope" > "${FAKE_CGROUP}"
}

teardown() {
    rm -rf "${TEST_DIR}"
}

make_fake_snap() {
    mkdir -p "$(dirname "${FAKE_SNAP_BIN}")"
    printf '#!/bin/sh\necho "mock-juju $@"\n' > "${FAKE_SNAP_BIN}"
    chmod +x "${FAKE_SNAP_BIN}"
}

make_sockets_writable() {
    touch "${FAKE_SNAP_SOCKET}" && chmod 660 "${FAKE_SNAP_SOCKET}"
    touch "${FAKE_LXD_SOCKET}" && chmod 660 "${FAKE_LXD_SOCKET}"
    touch "${FAKE_K8S_SOCKET}" && chmod 660 "${FAKE_K8S_SOCKET}"
}

patch_wrapper() {
    PATCHED="${TEST_DIR}/wrapper.sh"
    sed \
        -e "s|SNAP_BIN=\"/snap/bin/juju\"|SNAP_BIN=\"${FAKE_SNAP_BIN}\"|" \
        -e "s|/run/juju-installer-snap.socket|${FAKE_SNAP_SOCKET}|g" \
        -e "s|/run/juju-installer-lxd.socket|${FAKE_LXD_SOCKET}|g" \
        -e "s|/run/juju-installer-k8s.socket|${FAKE_K8S_SOCKET}|g" \
        -e "s|/proc/self/cgroup|${FAKE_CGROUP}|g" \
        "$@" \
        "${WRAPPER}" > "${PATCHED}"

    # Stub confirm_install to auto-accept
    sed -i 's/read -r answer < \/dev\/tty || answer="y"/answer="y"/' "${PATCHED}"

    # Stub all trigger functions to create fake snap binary
    _STUB="mkdir -p \"\$(dirname \"${FAKE_SNAP_BIN}\")\"; printf '#!/bin/sh\\\necho \"mock-juju \$@\"\\\n' > \"${FAKE_SNAP_BIN}\"; chmod +x \"${FAKE_SNAP_BIN}\""
    sed -i "/^trigger_snap_service() {/,/^}/c\\
trigger_snap_service() { ${_STUB}; }" "${PATCHED}"
    sed -i "/^trigger_lxd_service() {/,/^}/c\\
trigger_lxd_service() { ${_STUB}; }" "${PATCHED}"
    sed -i "/^trigger_k8s_service() {/,/^}/c\\
trigger_k8s_service() { ${_STUB}; }" "${PATCHED}"

    # Stub wait_for_snap to be instant
    sed -i "/^wait_for_snap() {/,/^}/ { s/sleep 1/sleep 0/; }" "${PATCHED}"

    # Stub controller/cloud/model checks based on env vars
    sed -i "/^has_lxd_controller() {/,/^}/c\\
has_lxd_controller() { [ \"\${MOCK_HAS_LXD_CONTROLLER:-0}\" -eq 1 ]; }" "${PATCHED}"
    sed -i "/^has_k8s_cloud() {/,/^}/c\\
has_k8s_cloud() { [ \"\${MOCK_HAS_K8S_CLOUD:-0}\" -eq 1 ]; }" "${PATCHED}"
    sed -i "/^has_k8s_controller() {/,/^}/c\\
has_k8s_controller() { [ \"\${MOCK_HAS_K8S_CONTROLLER:-0}\" -eq 1 ]; }" "${PATCHED}"
    sed -i "/^has_model() {/,/^}/c\\
has_model() { [ \"\${MOCK_HAS_MODEL:-0}\" -eq 1 ]; }" "${PATCHED}"

    # Stub bootstrap functions to just set BOOTSTRAPPED=1
    sed -i "/^do_bootstrap_lxd() {/,/^}/c\\
do_bootstrap_lxd() { BOOTSTRAPPED=1; }" "${PATCHED}"
    sed -i "/^do_bootstrap_k8s() {/,/^}/c\\
do_bootstrap_k8s() { BOOTSTRAPPED=1; }" "${PATCHED}"

    chmod +x "${PATCHED}"
}

run_patched() {
    set +e
    sh "${PATCHED}" "$@" 2>"${TEST_DIR}/stderr" >"${TEST_DIR}/stdout"
    LAST_RC=$?
    set -e
}

assert_stderr_contains() {
    if ! grep -q "$1" "${TEST_DIR}/stderr" 2>/dev/null; then
        echo "  ASSERT FAILED: stderr does not contain '$1'"
        echo "  stderr was: $(cat "${TEST_DIR}/stderr" 2>/dev/null)"
        return 1
    fi
    return 0
}

assert_stderr_not_contains() {
    if grep -q "$1" "${TEST_DIR}/stderr" 2>/dev/null; then
        echo "  ASSERT FAILED: stderr should not contain '$1'"
        echo "  stderr was: $(cat "${TEST_DIR}/stderr" 2>/dev/null)"
        return 1
    fi
    return 0
}

assert_stdout_contains() {
    if ! grep -q "$1" "${TEST_DIR}/stdout" 2>/dev/null; then
        echo "  ASSERT FAILED: stdout does not contain '$1'"
        echo "  stdout was: $(cat "${TEST_DIR}/stdout" 2>/dev/null)"
        return 1
    fi
    return 0
}

report() {
    name="$1"
    rc="$2"
    TOTAL=$((TOTAL + 1))
    if [ "$rc" -eq 0 ]; then
        PASS=$((PASS + 1))
        echo "  PASS: ${name}"
    else
        FAIL=$((FAIL + 1))
        echo "  FAIL: ${name}"
    fi
}

# ============================================================
# Tests
# ============================================================

echo "=== Substrate detection ==="

test_detect_lxd_charm() {
    setup
    make_sockets_writable
    patch_wrapper
    run_patched deploy postgresql
    result=0
    assert_stderr_contains "LXD snaps" || result=1
    assert_stderr_not_contains "K8s" || result=1
    teardown
    return $result
}
test_detect_lxd_charm; report "postgresql -> LXD path" $?

test_detect_k8s_charm() {
    setup
    make_sockets_writable
    patch_wrapper
    run_patched deploy postgresql-k8s --trust
    result=0
    assert_stderr_contains "Canonical K8s snaps" || result=1
    teardown
    return $result
}
test_detect_k8s_charm; report "postgresql-k8s -> K8s path" $?

test_detect_k8s_mongodb() {
    setup
    make_sockets_writable
    patch_wrapper
    run_patched deploy mongodb-k8s
    result=0
    assert_stderr_contains "Canonical K8s snaps" || result=1
    teardown
    return $result
}
test_detect_k8s_mongodb; report "mongodb-k8s -> K8s path" $?

test_detect_workloadless_charm() {
    setup
    make_sockets_writable
    patch_wrapper
    run_patched deploy data-integrator
    result=0
    assert_stderr_contains "LXD snaps" || result=1
    assert_stderr_not_contains "K8s" || result=1
    teardown
    return $result
}
test_detect_workloadless_charm; report "data-integrator -> LXD path" $?

echo ""
echo "=== Charm name extraction ==="

test_extract_with_flags_before() {
    setup
    make_sockets_writable
    patch_wrapper
    run_patched deploy --channel 14/edge postgresql-k8s --trust
    result=0
    assert_stderr_contains "Canonical K8s snaps" || result=1
    teardown
    return $result
}
test_extract_with_flags_before; report "flags before charm name handled" $?

test_extract_with_equals_flag() {
    setup
    make_sockets_writable
    patch_wrapper
    run_patched deploy --channel=14/edge postgresql-k8s
    result=0
    assert_stderr_contains "Canonical K8s snaps" || result=1
    teardown
    return $result
}
test_extract_with_equals_flag; report "--channel=val flag handled" $?

test_extract_plain_charm() {
    setup
    make_sockets_writable
    patch_wrapper
    run_patched deploy postgresql
    result=0
    assert_stderr_contains "LXD snaps" || result=1
    teardown
    return $result
}
test_extract_plain_charm; report "plain charm name extracted" $?

echo ""
echo "=== Non-deploy commands ==="

test_nondeploy_snap_only_prompt() {
    setup
    make_sockets_writable
    patch_wrapper
    sed -i 's/answer="y"/answer="n"/' "${PATCHED}"
    run_patched version
    result=0
    assert_stderr_contains "install Juju snap now" || result=1
    assert_stderr_not_contains "LXD" || result=1
    assert_stderr_not_contains "K8s" || result=1
    teardown
    return $result
}
test_nondeploy_snap_only_prompt; report "non-deploy: snap-only prompt, no substrate" $?

test_nondeploy_no_bootstrap() {
    setup
    make_sockets_writable
    patch_wrapper
    run_patched version
    result=0
    assert_stderr_not_contains "Bootstrapping" || result=1
    assert_stderr_not_contains "Hint:" || result=1
    teardown
    return $result
}
test_nondeploy_no_bootstrap; report "non-deploy: no bootstrap" $?

echo ""
echo "=== Root user check ==="

test_root_blocked_deploy() {
    setup
    patch_wrapper -e 's/$(id -u)/0/g'
    run_patched deploy postgresql
    result=0
    [ "$LAST_RC" -ne 0 ] || { echo "  ASSERT FAILED: expected non-zero exit"; result=1; }
    assert_stderr_contains "Do not run 'juju deploy' as root" || result=1
    teardown
    return $result
}
test_root_blocked_deploy; report "root blocked on deploy" $?

test_root_allowed_passthrough() {
    setup
    make_fake_snap
    patch_wrapper -e 's/$(id -u)/0/g'
    run_patched version
    result=0
    [ "$LAST_RC" -eq 0 ] || { echo "  ASSERT FAILED: expected exit 0"; result=1; }
    assert_stdout_contains "mock-juju" || result=1
    teardown
    return $result
}
test_root_allowed_passthrough; report "root allowed on passthrough" $?

echo ""
echo "=== Cgroup check ==="

test_cgroup_blocks() {
    setup
    echo "0::/system.slice/lxd-agent.service" > "${FAKE_CGROUP}"
    make_sockets_writable
    patch_wrapper
    run_patched deploy postgresql
    result=0
    [ "$LAST_RC" -ne 0 ] || { echo "  ASSERT FAILED: expected non-zero exit"; result=1; }
    assert_stderr_contains "not running in a regular login session" || result=1
    teardown
    return $result
}
test_cgroup_blocks; report "cgroup blocks system.slice" $?

test_cgroup_allows_user() {
    setup
    make_sockets_writable
    patch_wrapper
    run_patched deploy postgresql
    result=0
    assert_stderr_not_contains "not running in a regular login session" || result=1
    teardown
    return $result
}
test_cgroup_allows_user; report "cgroup allows user.slice" $?

echo ""
echo "=== Socket access check ==="

test_socket_not_writable() {
    setup
    patch_wrapper
    run_patched version
    result=0
    [ "$LAST_RC" -ne 0 ] || { echo "  ASSERT FAILED: expected non-zero exit"; result=1; }
    assert_stderr_contains "Unable to trigger the installation of Juju" || result=1
    teardown
    return $result
}
test_socket_not_writable; report "socket not writable" $?

echo ""
echo "=== Confirm install ==="

test_confirm_abort() {
    setup
    make_sockets_writable
    patch_wrapper
    sed -i 's/answer="y"/answer="n"/' "${PATCHED}"
    run_patched deploy postgresql
    result=0
    [ "$LAST_RC" -eq 0 ] || { echo "  ASSERT FAILED: expected exit 0 (abort is clean)"; result=1; }
    assert_stderr_contains "Aborted" || result=1
    teardown
    return $result
}
test_confirm_abort; report "user aborts install" $?

echo ""
echo "=== Passthrough ==="

test_passthrough_silent() {
    setup
    make_fake_snap
    patch_wrapper
    run_patched version
    result=0
    assert_stdout_contains "mock-juju" || result=1
    if [ -s "${TEST_DIR}/stderr" ]; then
        echo "  ASSERT FAILED: stderr should be empty on passthrough"
        result=1
    fi
    teardown
    return $result
}
test_passthrough_silent; report "passthrough is silent" $?

test_passthrough_deploy_silent() {
    setup
    make_fake_snap
    patch_wrapper
    run_patched deploy postgresql
    result=0
    assert_stdout_contains "mock-juju" || result=1
    assert_stderr_not_contains "Hint:" || result=1
    teardown
    return $result
}
test_passthrough_deploy_silent; report "passthrough deploy is silent" $?

echo ""
echo "=== Hint display ==="

test_hint_after_lxd_bootstrap() {
    setup
    make_sockets_writable
    patch_wrapper
    run_patched deploy postgresql
    result=0
    assert_stderr_contains "Hint: run 'juju status'" || result=1
    teardown
    return $result
}
test_hint_after_lxd_bootstrap; report "hint after LXD bootstrap" $?

test_hint_after_k8s_bootstrap() {
    setup
    make_sockets_writable
    patch_wrapper
    run_patched deploy postgresql-k8s --trust
    result=0
    assert_stderr_contains "Hint: run 'juju status'" || result=1
    teardown
    return $result
}
test_hint_after_k8s_bootstrap; report "hint after K8s bootstrap" $?

echo ""
echo "=== Progress messages ==="

test_lxd_progress_step_count() {
    setup
    make_sockets_writable
    patch_wrapper
    run_patched deploy postgresql
    result=0
    assert_stderr_contains "\[1/5\]" || result=1
    teardown
    return $result
}
test_lxd_progress_step_count; report "LXD path shows [1/5]" $?

test_k8s_progress_step_count() {
    setup
    make_sockets_writable
    patch_wrapper
    run_patched deploy postgresql-k8s
    result=0
    assert_stderr_contains "\[1/9\]" || result=1
    teardown
    return $result
}
test_k8s_progress_step_count; report "K8s path shows [1/9]" $?

# ============================================================
# Summary
# ============================================================

echo ""
echo "=== Results: ${PASS}/${TOTAL} passed, ${FAIL} failed ==="
[ "$FAIL" -eq 0 ] || exit 1
