#!/bin/sh
# Unit tests for /sbin/juju wrapper script.
# Run: sh tests/test_wrapper.sh
#
# These tests mock the snap binary, socket, and /proc/self/cgroup
# to exercise wrapper logic without real snaps or systemd.
set -eu

WRAPPER="$(cd "$(dirname "$0")/.." && pwd)/sbin/juju"
PASS=0
FAIL=0
TOTAL=0

setup() {
    TEST_DIR=$(mktemp -d)
    FAKE_SNAP_BIN="${TEST_DIR}/snap/bin/juju"
    FAKE_SOCKET="${TEST_DIR}/run/juju-installer.socket"
    FAKE_CGROUP="${TEST_DIR}/proc_self_cgroup"

    mkdir -p "${TEST_DIR}/snap/bin" "${TEST_DIR}/run"

    echo "0::/user.slice/user-1000.slice/session-1.scope" > "${FAKE_CGROUP}"
}

teardown() {
    rm -rf "${TEST_DIR}"
}

run_wrapper() {
    # Build a patched copy of the wrapper for each test run:
    # - Replace SNAP_BIN path
    # - Replace socket path
    # - Replace /proc/self/cgroup path
    # - Replace confirm_install to auto-accept (no tty in tests)
    # - Replace trigger_service to just touch the snap binary
    PATCHED="${TEST_DIR}/wrapper.sh"
    sed \
        -e "s|SNAP_BIN=\"/snap/bin/juju\"|SNAP_BIN=\"${FAKE_SNAP_BIN}\"|" \
        -e "s|/run/juju-installer.socket|${FAKE_SOCKET}|g" \
        -e "s|/proc/self/cgroup|${FAKE_CGROUP}|g" \
        "${WRAPPER}" > "${PATCHED}"

    # Stub confirm_install to auto-accept
    sed -i 's/read -r answer < \/dev\/tty || answer="y"/answer="y"/' "${PATCHED}"

    # Stub trigger_service to create the fake snap binary
    cat >> "${PATCHED}.trigger" <<STUB
trigger_service() {
    mkdir -p "\$(dirname "${FAKE_SNAP_BIN}")"
    printf '#!/bin/sh\necho "mock-juju \$@"\n' > "${FAKE_SNAP_BIN}"
    chmod +x "${FAKE_SNAP_BIN}"
}
STUB
    # Inject the stub after the original trigger_service definition
    sed -i "/^trigger_service() {/,/^}/ {
        /^}/a\\
# --- stubbed trigger_service ---
        /^}/r ${PATCHED}.trigger
    }" "${PATCHED}"
    # Actually replace: just redefine at the top after SNAP_BIN
    sed -i "/^SNAP_BIN=/a\\
trigger_service() { mkdir -p \"\$(dirname \"${FAKE_SNAP_BIN}\")\"; printf '#!/bin/sh\\\\necho \"mock-juju \$@\"\\\\n' > \"${FAKE_SNAP_BIN}\"; chmod +x \"${FAKE_SNAP_BIN}\"; }" "${PATCHED}"

    # Stub wait_for_snap to be instant (snap created by trigger_service)
    sed -i "/^wait_for_snap() {/,/^}/ {
        s/sleep 1/sleep 0/
    }" "${PATCHED}"

    # Stub has_controller and has_model based on env vars
    sed -i "/^has_controller() {/,/^}/c\\
has_controller() { [ \"\${MOCK_HAS_CONTROLLER:-0}\" -eq 1 ]; }" "${PATCHED}"
    sed -i "/^has_model() {/,/^}/c\\
has_model() { [ \"\${MOCK_HAS_MODEL:-0}\" -eq 1 ]; }" "${PATCHED}"

    # Stub do_bootstrap to just set BOOTSTRAPPED=1 (no real juju)
    sed -i "/^do_bootstrap() {/,/^}/c\\
do_bootstrap() { BOOTSTRAPPED=1; }" "${PATCHED}"

    chmod +x "${PATCHED}"
    sh "${PATCHED}" "$@" 2>"${TEST_DIR}/stderr" >"${TEST_DIR}/stdout"
}

assert_exits() {
    expected_rc="$1"
    shift
    PATCHED="${TEST_DIR}/wrapper.sh"
    sed \
        -e "s|SNAP_BIN=\"/snap/bin/juju\"|SNAP_BIN=\"${FAKE_SNAP_BIN}\"|" \
        -e "s|/run/juju-installer.socket|${FAKE_SOCKET}|g" \
        -e "s|/proc/self/cgroup|${FAKE_CGROUP}|g" \
        "${WRAPPER}" > "${PATCHED}"
    sed -i 's/read -r answer < \/dev\/tty || answer="y"/answer="y"/' "${PATCHED}"
    sed -i "/^SNAP_BIN=/a\\
trigger_service() { mkdir -p \"\$(dirname \"${FAKE_SNAP_BIN}\")\"; printf '#!/bin/sh\\\\necho \"mock-juju \$@\"\\\\n' > \"${FAKE_SNAP_BIN}\"; chmod +x \"${FAKE_SNAP_BIN}\"; }" "${PATCHED}"
    sed -i "/^wait_for_snap() {/,/^}/ { s/sleep 1/sleep 0/; }" "${PATCHED}"
    sed -i "/^has_controller() {/,/^}/c\\
has_controller() { [ \"\${MOCK_HAS_CONTROLLER:-0}\" -eq 1 ]; }" "${PATCHED}"
    sed -i "/^has_model() {/,/^}/c\\
has_model() { [ \"\${MOCK_HAS_MODEL:-0}\" -eq 1 ]; }" "${PATCHED}"
    sed -i "/^do_bootstrap() {/,/^}/c\\
do_bootstrap() { BOOTSTRAPPED=1; }" "${PATCHED}"
    chmod +x "${PATCHED}"

    set +e
    sh "${PATCHED}" "$@" 2>"${TEST_DIR}/stderr" >"${TEST_DIR}/stdout"
    actual_rc=$?
    set -e

    if [ "$actual_rc" -ne "$expected_rc" ]; then
        echo "  ASSERT FAILED: expected exit code ${expected_rc}, got ${actual_rc}"
        cat "${TEST_DIR}/stderr" 2>/dev/null
        return 1
    fi
    return 0
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

echo "=== Root user check ==="

test_root_check_blocks_when_no_snap() {
    setup
    # Simulate root: override check_user's id -u to return 0
    PATCHED="${TEST_DIR}/wrapper.sh"
    sed \
        -e "s|SNAP_BIN=\"/snap/bin/juju\"|SNAP_BIN=\"${FAKE_SNAP_BIN}\"|" \
        -e "s|/run/juju-installer.socket|${FAKE_SOCKET}|g" \
        -e "s|/proc/self/cgroup|${FAKE_CGROUP}|g" \
        -e 's/$(id -u)/0/g' \
        "${WRAPPER}" > "${PATCHED}"
    chmod +x "${PATCHED}"
    set +e
    sh "${PATCHED}" deploy postgresql 2>"${TEST_DIR}/stderr" >"${TEST_DIR}/stdout"
    rc=$?
    set -e
    result=0
    [ "$rc" -ne 0 ] || { echo "  ASSERT FAILED: expected non-zero exit"; result=1; }
    assert_stderr_contains "Do not run 'juju deploy' as root" || result=1
    assert_stderr_contains "Run as a regular user" || result=1
    teardown
    return $result
}
test_root_check_blocks_when_no_snap; report "root blocked (no snap, deploy)" $?

test_root_check_blocks_when_snap_exists_no_controller() {
    setup
    mkdir -p "$(dirname "${FAKE_SNAP_BIN}")"
    printf '#!/bin/sh\necho "mock"\n' > "${FAKE_SNAP_BIN}"
    chmod +x "${FAKE_SNAP_BIN}"
    PATCHED="${TEST_DIR}/wrapper.sh"
    sed \
        -e "s|SNAP_BIN=\"/snap/bin/juju\"|SNAP_BIN=\"${FAKE_SNAP_BIN}\"|" \
        -e "s|/run/juju-installer.socket|${FAKE_SOCKET}|g" \
        -e "s|/proc/self/cgroup|${FAKE_CGROUP}|g" \
        -e 's/$(id -u)/0/g' \
        "${WRAPPER}" > "${PATCHED}"
    sed -i "/^has_controller() {/,/^}/c\\
has_controller() { return 1; }" "${PATCHED}"
    sed -i "/^has_model() {/,/^}/c\\
has_model() { return 1; }" "${PATCHED}"
    chmod +x "${PATCHED}"
    set +e
    sh "${PATCHED}" deploy postgresql 2>"${TEST_DIR}/stderr" >"${TEST_DIR}/stdout"
    rc=$?
    set -e
    result=0
    [ "$rc" -ne 0 ] || { echo "  ASSERT FAILED: expected non-zero exit"; result=1; }
    assert_stderr_contains "Do not run 'juju deploy' as root" || result=1
    teardown
    return $result
}
test_root_check_blocks_when_snap_exists_no_controller; report "root blocked (snap exists, no controller, deploy)" $?

test_root_check_skipped_on_passthrough() {
    setup
    mkdir -p "$(dirname "${FAKE_SNAP_BIN}")"
    printf '#!/bin/sh\necho "mock-version"\n' > "${FAKE_SNAP_BIN}"
    chmod +x "${FAKE_SNAP_BIN}"
    PATCHED="${TEST_DIR}/wrapper.sh"
    sed \
        -e "s|SNAP_BIN=\"/snap/bin/juju\"|SNAP_BIN=\"${FAKE_SNAP_BIN}\"|" \
        -e "s|/run/juju-installer.socket|${FAKE_SOCKET}|g" \
        -e "s|/proc/self/cgroup|${FAKE_CGROUP}|g" \
        -e 's/$(id -u)/0/g' \
        "${WRAPPER}" > "${PATCHED}"
    sed -i "/^has_controller() {/,/^}/c\\
has_controller() { return 0; }" "${PATCHED}"
    sed -i "/^has_model() {/,/^}/c\\
has_model() { return 0; }" "${PATCHED}"
    chmod +x "${PATCHED}"
    set +e
    sh "${PATCHED}" version 2>"${TEST_DIR}/stderr" >"${TEST_DIR}/stdout"
    rc=$?
    set -e
    result=0
    [ "$rc" -eq 0 ] || { echo "  ASSERT FAILED: expected exit 0, got $rc"; result=1; }
    assert_stderr_not_contains "Do not run" || result=1
    assert_stdout_contains "mock-version" || result=1
    teardown
    return $result
}
test_root_check_skipped_on_passthrough; report "root allowed on passthrough (non-deploy)" $?

echo ""
echo "=== Cgroup check ==="

test_cgroup_blocks_system_service() {
    setup
    echo "0::/system.slice/lxd-agent.service" > "${FAKE_CGROUP}"
    # No snap installed, writable socket needed
    touch "${FAKE_SOCKET}" && chmod 660 "${FAKE_SOCKET}"
    assert_exits 1 deploy postgresql
    result=0
    assert_stderr_contains "not running in a regular login session" || result=1
    assert_stderr_contains "Use SSH or log in directly" || result=1
    teardown
    return $result
}
test_cgroup_blocks_system_service; report "cgroup blocks system.slice service" $?

test_cgroup_allows_user_session() {
    setup
    echo "0::/user.slice/user-1000.slice/session-1.scope" > "${FAKE_CGROUP}"
    touch "${FAKE_SOCKET}" && chmod 660 "${FAKE_SOCKET}"
    # run_wrapper will auto-install fake snap and bootstrap
    run_wrapper deploy postgresql
    result=0
    assert_stderr_not_contains "not running in a regular login session" || result=1
    teardown
    return $result
}
test_cgroup_allows_user_session; report "cgroup allows user.slice session" $?

test_cgroup_blocks_on_bootstrap_path() {
    setup
    echo "0::/system.slice/lxd-agent.service" > "${FAKE_CGROUP}"
    # Snap exists but no controller — should hit cgroup check on bootstrap path
    mkdir -p "$(dirname "${FAKE_SNAP_BIN}")"
    printf '#!/bin/sh\necho "mock"\n' > "${FAKE_SNAP_BIN}"
    chmod +x "${FAKE_SNAP_BIN}"
    PATCHED="${TEST_DIR}/wrapper.sh"
    sed \
        -e "s|SNAP_BIN=\"/snap/bin/juju\"|SNAP_BIN=\"${FAKE_SNAP_BIN}\"|" \
        -e "s|/run/juju-installer.socket|${FAKE_SOCKET}|g" \
        -e "s|/proc/self/cgroup|${FAKE_CGROUP}|g" \
        "${WRAPPER}" > "${PATCHED}"
    sed -i "/^has_controller() {/,/^}/c\\
has_controller() { return 1; }" "${PATCHED}"
    sed -i "/^has_model() {/,/^}/c\\
has_model() { return 1; }" "${PATCHED}"
    chmod +x "${PATCHED}"
    set +e
    sh "${PATCHED}" deploy postgresql 2>"${TEST_DIR}/stderr" >"${TEST_DIR}/stdout"
    rc=$?
    set -e
    result=0
    [ "$rc" -ne 0 ] || { echo "  ASSERT FAILED: expected non-zero exit"; result=1; }
    assert_stderr_contains "not running in a regular login session" || result=1
    teardown
    return $result
}
test_cgroup_blocks_on_bootstrap_path; report "cgroup blocks on bootstrap path (snap exists)" $?

echo ""
echo "=== Socket access check ==="

test_socket_not_writable() {
    setup
    echo "0::/user.slice/user-1000.slice/session-1.scope" > "${FAKE_CGROUP}"
    # No socket file at all
    assert_exits 1 version
    result=0
    assert_stderr_contains "Unable to trigger the installation of Juju" || result=1
    assert_stderr_contains "member of the 'lxd' system group" || result=1
    teardown
    return $result
}
test_socket_not_writable; report "socket not writable" $?

echo ""
echo "=== Confirm install ==="

test_confirm_abort() {
    setup
    touch "${FAKE_SOCKET}" && chmod 660 "${FAKE_SOCKET}"
    PATCHED="${TEST_DIR}/wrapper.sh"
    sed \
        -e "s|SNAP_BIN=\"/snap/bin/juju\"|SNAP_BIN=\"${FAKE_SNAP_BIN}\"|" \
        -e "s|/run/juju-installer.socket|${FAKE_SOCKET}|g" \
        -e "s|/proc/self/cgroup|${FAKE_CGROUP}|g" \
        -e 's/read -r answer < \/dev\/tty || answer="y"/answer="n"/' \
        "${WRAPPER}" > "${PATCHED}"
    chmod +x "${PATCHED}"
    set +e
    sh "${PATCHED}" version 2>"${TEST_DIR}/stderr" >"${TEST_DIR}/stdout"
    rc=$?
    set -e
    result=0
    [ "$rc" -eq 0 ] || { echo "  ASSERT FAILED: expected exit 0 (abort is clean), got $rc"; result=1; }
    assert_stderr_contains "Aborted" || result=1
    teardown
    return $result
}
test_confirm_abort; report "user aborts install confirmation" $?

test_confirm_deploy_prompt() {
    setup
    touch "${FAKE_SOCKET}" && chmod 660 "${FAKE_SOCKET}"
    PATCHED="${TEST_DIR}/wrapper.sh"
    sed \
        -e "s|SNAP_BIN=\"/snap/bin/juju\"|SNAP_BIN=\"${FAKE_SNAP_BIN}\"|" \
        -e "s|/run/juju-installer.socket|${FAKE_SOCKET}|g" \
        -e "s|/proc/self/cgroup|${FAKE_CGROUP}|g" \
        -e 's/read -r answer < \/dev\/tty || answer="y"/answer="n"/' \
        "${WRAPPER}" > "${PATCHED}"
    chmod +x "${PATCHED}"
    set +e
    sh "${PATCHED}" deploy postgresql 2>"${TEST_DIR}/stderr" >"${TEST_DIR}/stdout"
    rc=$?
    set -e
    result=0
    assert_stderr_contains "install Juju snaps now" || result=1
    teardown
    return $result
}
test_confirm_deploy_prompt; report "deploy shows plural 'snaps' prompt" $?

test_confirm_nondeploy_prompt() {
    setup
    touch "${FAKE_SOCKET}" && chmod 660 "${FAKE_SOCKET}"
    PATCHED="${TEST_DIR}/wrapper.sh"
    sed \
        -e "s|SNAP_BIN=\"/snap/bin/juju\"|SNAP_BIN=\"${FAKE_SNAP_BIN}\"|" \
        -e "s|/run/juju-installer.socket|${FAKE_SOCKET}|g" \
        -e "s|/proc/self/cgroup|${FAKE_CGROUP}|g" \
        -e 's/read -r answer < \/dev\/tty || answer="y"/answer="n"/' \
        "${WRAPPER}" > "${PATCHED}"
    chmod +x "${PATCHED}"
    set +e
    sh "${PATCHED}" version 2>"${TEST_DIR}/stderr" >"${TEST_DIR}/stdout"
    rc=$?
    set -e
    result=0
    assert_stderr_contains "install Juju snap now" || result=1
    assert_stderr_not_contains "snaps" || result=1
    teardown
    return $result
}
test_confirm_nondeploy_prompt; report "non-deploy shows singular 'snap' prompt" $?

echo ""
echo "=== is_deploy_command ==="

test_deploy_triggers_bootstrap() {
    setup
    touch "${FAKE_SOCKET}" && chmod 660 "${FAKE_SOCKET}"
    export MOCK_HAS_CONTROLLER=0 MOCK_HAS_MODEL=0
    run_wrapper deploy postgresql
    result=0
    assert_stdout_contains "mock-juju" || result=1
    assert_stderr_contains "Hint: run 'juju status'" || result=1
    unset MOCK_HAS_CONTROLLER MOCK_HAS_MODEL
    teardown
    return $result
}
test_deploy_triggers_bootstrap; report "deploy triggers bootstrap + shows hint" $?

test_nondeploy_no_bootstrap() {
    setup
    touch "${FAKE_SOCKET}" && chmod 660 "${FAKE_SOCKET}"
    export MOCK_HAS_CONTROLLER=0 MOCK_HAS_MODEL=0
    run_wrapper version
    result=0
    assert_stderr_not_contains "Bootstrapping" || result=1
    assert_stderr_not_contains "Hint:" || result=1
    teardown
    return $result
}
test_nondeploy_no_bootstrap; report "non-deploy skips bootstrap" $?

echo ""
echo "=== Passthrough ==="

test_passthrough_silent() {
    setup
    mkdir -p "$(dirname "${FAKE_SNAP_BIN}")"
    printf '#!/bin/sh\necho "juju-version-output"\n' > "${FAKE_SNAP_BIN}"
    chmod +x "${FAKE_SNAP_BIN}"
    export MOCK_HAS_CONTROLLER=1 MOCK_HAS_MODEL=1
    run_wrapper version
    result=0
    assert_stdout_contains "juju-version-output" || result=1
    # Passthrough should produce no wrapper output on stderr
    if [ -s "${TEST_DIR}/stderr" ]; then
        echo "  ASSERT FAILED: stderr should be empty on passthrough"
        echo "  stderr was: $(cat "${TEST_DIR}/stderr")"
        result=1
    fi
    unset MOCK_HAS_CONTROLLER MOCK_HAS_MODEL
    teardown
    return $result
}
test_passthrough_silent; report "passthrough is silent" $?

test_passthrough_deploy_silent() {
    setup
    mkdir -p "$(dirname "${FAKE_SNAP_BIN}")"
    printf '#!/bin/sh\necho "deploying..."\n' > "${FAKE_SNAP_BIN}"
    chmod +x "${FAKE_SNAP_BIN}"
    export MOCK_HAS_CONTROLLER=1 MOCK_HAS_MODEL=1
    run_wrapper deploy postgresql
    result=0
    assert_stdout_contains "deploying" || result=1
    assert_stderr_not_contains "Hint:" || result=1
    unset MOCK_HAS_CONTROLLER MOCK_HAS_MODEL
    teardown
    return $result
}
test_passthrough_deploy_silent; report "passthrough deploy is silent (no hint)" $?

echo ""
echo "=== Hint display ==="

test_hint_only_after_bootstrap() {
    setup
    touch "${FAKE_SOCKET}" && chmod 660 "${FAKE_SOCKET}"
    export MOCK_HAS_CONTROLLER=0 MOCK_HAS_MODEL=0
    run_wrapper deploy postgresql
    result=0
    assert_stderr_contains "Hint: run 'juju status' to track deployment progress" || result=1
    unset MOCK_HAS_CONTROLLER MOCK_HAS_MODEL
    teardown
    return $result
}
test_hint_only_after_bootstrap; report "hint shown after bootstrap" $?

# ============================================================
# Summary
# ============================================================

echo ""
echo "=== Results: ${PASS}/${TOTAL} passed, ${FAIL} failed ==="
[ "$FAIL" -eq 0 ] || exit 1
