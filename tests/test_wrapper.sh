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
    [ -e "${FAKE_SNAP_SOCKET}" ] || { touch "${FAKE_SNAP_SOCKET}" && chmod 660 "${FAKE_SNAP_SOCKET}"; }
    [ -e "${FAKE_LXD_SOCKET}" ]  || { touch "${FAKE_LXD_SOCKET}"  && chmod 660 "${FAKE_LXD_SOCKET}";  }
    [ -e "${FAKE_K8S_SOCKET}" ]  || { touch "${FAKE_K8S_SOCKET}"  && chmod 660 "${FAKE_K8S_SOCKET}";  }
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

test_extract_trust_before_charm() {
    setup
    make_sockets_writable
    patch_wrapper
    run_patched deploy --trust postgresql-k8s
    result=0
    assert_stderr_contains "Canonical K8s snaps" || result=1
    teardown
    return $result
}
test_extract_trust_before_charm; report "--trust before charm name handled" $?

test_extract_trust_after_charm() {
    setup
    make_sockets_writable
    patch_wrapper
    run_patched deploy postgresql-k8s --trust
    result=0
    assert_stderr_contains "Canonical K8s snaps" || result=1
    teardown
    return $result
}
test_extract_trust_after_charm; report "--trust after charm name handled" $?

echo ""
echo "=== Global flags before subcommand ==="

test_global_flag_before_deploy() {
    setup
    make_sockets_writable
    patch_wrapper
    run_patched --verbose deploy postgresql
    result=0
    assert_stderr_contains "LXD snaps" || result=1
    teardown
    return $result
}
test_global_flag_before_deploy; report "--verbose deploy triggers install" $?

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
    patch_wrapper -e "s/\$(id -u)/0/g"
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
    patch_wrapper -e "s/\$(id -u)/0/g"
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

echo ""
echo "=== Edge cases ==="

test_deploy_no_charm_name() {
    setup
    make_sockets_writable
    patch_wrapper
    run_patched deploy
    result=0
    assert_stderr_contains "LXD snaps" || result=1
    teardown
    return $result
}
test_deploy_no_charm_name; report "deploy with no charm name defaults to LXD" $?

test_deploy_ch_prefix_k8s() {
    setup
    make_sockets_writable
    patch_wrapper
    run_patched deploy ch:postgresql-k8s
    result=0
    assert_stderr_contains "Canonical K8s snaps" || result=1
    teardown
    return $result
}
test_deploy_ch_prefix_k8s; report "ch:postgresql-k8s -> K8s path" $?

test_deploy_local_path() {
    setup
    make_sockets_writable
    patch_wrapper
    run_patched deploy ./local-charm
    result=0
    assert_stderr_contains "LXD snaps" || result=1
    teardown
    return $result
}
test_deploy_local_path; report "./local-charm -> LXD path" $?

test_deploy_many_flags() {
    setup
    make_sockets_writable
    patch_wrapper
    run_patched deploy --channel 14/edge --num-units 3 postgresql-k8s --trust
    result=0
    assert_stderr_contains "Canonical K8s snaps" || result=1
    teardown
    return $result
}
test_deploy_many_flags; report "multiple combined flags handled" $?

echo ""
echo "=== Exit code propagation ==="

test_exit_code_passthrough() {
    setup
    mkdir -p "$(dirname "${FAKE_SNAP_BIN}")"
    printf '#!/bin/sh\nexit 42\n' > "${FAKE_SNAP_BIN}"
    chmod +x "${FAKE_SNAP_BIN}"
    patch_wrapper
    run_patched version
    result=0
    [ "$LAST_RC" -eq 42 ] || { echo "  ASSERT FAILED: expected exit 42, got $LAST_RC"; result=1; }
    teardown
    return $result
}
test_exit_code_passthrough; report "exit code propagated on passthrough" $?

test_exit_code_after_bootstrap() {
    setup
    make_sockets_writable
    patch_wrapper
    # Override mock-juju to exit 42 on deploy, 0 on everything else
    sed -i "s|echo \"mock-juju \$@\"|case \"\$1\" in deploy) exit 42;; *) echo \"mock-juju \$@\";; esac|" "${PATCHED}"
    run_patched deploy postgresql
    result=0
    [ "$LAST_RC" -eq 42 ] || { echo "  ASSERT FAILED: expected exit 42, got $LAST_RC"; result=1; }
    teardown
    return $result
}
test_exit_code_after_bootstrap; report "exit code propagated after bootstrap" $?

echo ""
echo "=== wait_for_snap timeout ==="

test_wait_for_snap_timeout() {
    setup
    make_sockets_writable
    # Build a custom patched wrapper that keeps wait_for_snap but with short timeout
    PATCHED="${TEST_DIR}/wrapper.sh"
    sed \
        -e "s|SNAP_BIN=\"/snap/bin/juju\"|SNAP_BIN=\"${FAKE_SNAP_BIN}\"|" \
        -e "s|/run/juju-installer-snap.socket|${FAKE_SNAP_SOCKET}|g" \
        -e "s|/run/juju-installer-lxd.socket|${FAKE_LXD_SOCKET}|g" \
        -e "s|/run/juju-installer-k8s.socket|${FAKE_K8S_SOCKET}|g" \
        -e "s|/proc/self/cgroup|${FAKE_CGROUP}|g" \
        "${WRAPPER}" > "${PATCHED}"
    sed -i 's/read -r answer < \/dev\/tty || answer="y"/answer="y"/' "${PATCHED}"
    # trigger_snap_service does nothing (snap binary never appears)
    sed -i "/^trigger_snap_service() {/,/^}/c\\
trigger_snap_service() { :; }" "${PATCHED}"
    # Reduce wait_for_snap to 1 iteration with no sleep
    sed -i 's/while \[ "\$i" -lt 90 \]/while [ "$i" -lt 1 ]/' "${PATCHED}"
    sed -i '/wait_for_snap/,/^}/ s/sleep 1/sleep 0/' "${PATCHED}"
    chmod +x "${PATCHED}"
    run_patched version
    result=0
    [ "$LAST_RC" -ne 0 ] || { echo "  ASSERT FAILED: expected non-zero exit"; result=1; }
    assert_stderr_contains "timed out" || result=1
    teardown
    return $result
}
test_wait_for_snap_timeout; report "wait_for_snap timeout exits with error" $?

echo ""
echo "=== Bootstrap idempotency (LXD) ==="

patch_wrapper_with_real_bootstrap_lxd() {
    PATCHED="${TEST_DIR}/wrapper.sh"
    sed \
        -e "s|SNAP_BIN=\"/snap/bin/juju\"|SNAP_BIN=\"${FAKE_SNAP_BIN}\"|" \
        -e "s|/run/juju-installer-snap.socket|${FAKE_SNAP_SOCKET}|g" \
        -e "s|/run/juju-installer-lxd.socket|${FAKE_LXD_SOCKET}|g" \
        -e "s|/run/juju-installer-k8s.socket|${FAKE_K8S_SOCKET}|g" \
        -e "s|/proc/self/cgroup|${FAKE_CGROUP}|g" \
        "${WRAPPER}" > "${PATCHED}"
    sed -i 's/read -r answer < \/dev\/tty || answer="y"/answer="y"/' "${PATCHED}"

    _STUB="mkdir -p \"\$(dirname \"${FAKE_SNAP_BIN}\")\"; printf '#!/bin/sh\\\necho \"mock-juju \$@\"\\\n' > \"${FAKE_SNAP_BIN}\"; chmod +x \"${FAKE_SNAP_BIN}\""
    sed -i "/^trigger_snap_service() {/,/^}/c\\
trigger_snap_service() { ${_STUB}; }" "${PATCHED}"
    sed -i "/^trigger_lxd_service() {/,/^}/c\\
trigger_lxd_service() { ${_STUB}; }" "${PATCHED}"
    sed -i "/^trigger_k8s_service() {/,/^}/c\\
trigger_k8s_service() { ${_STUB}; }" "${PATCHED}"
    sed -i "/^wait_for_snap() {/,/^}/ { s/sleep 1/sleep 0/; }" "${PATCHED}"

    # Stub has_* checks based on env vars (keep real bootstrap functions)
    sed -i "/^has_lxd_controller() {/,/^}/c\\
has_lxd_controller() { [ \"\${MOCK_HAS_LXD_CONTROLLER:-0}\" -eq 1 ]; }" "${PATCHED}"
    sed -i "/^has_k8s_cloud() {/,/^}/c\\
has_k8s_cloud() { [ \"\${MOCK_HAS_K8S_CLOUD:-0}\" -eq 1 ]; }" "${PATCHED}"
    sed -i "/^has_k8s_controller() {/,/^}/c\\
has_k8s_controller() { [ \"\${MOCK_HAS_K8S_CONTROLLER:-0}\" -eq 1 ]; }" "${PATCHED}"
    sed -i "/^has_model() {/,/^}/c\\
has_model() { [ \"\${MOCK_HAS_MODEL:-0}\" -eq 1 ]; }" "${PATCHED}"

    # do_bootstrap_k8s reads kubeconfig from /run/ — redirect to test dir
    sed -i "s|/run/juju-installer-k8s-kubeconfig|${TEST_DIR}/kubeconfig|g" "${PATCHED}"

    chmod +x "${PATCHED}"
}

test_lxd_skip_existing_controller() {
    setup
    make_sockets_writable
    patch_wrapper_with_real_bootstrap_lxd
    MOCK_HAS_LXD_CONTROLLER=1 run_patched deploy postgresql
    result=0
    assert_stderr_not_contains "Bootstrapping" || result=1
    assert_stderr_contains "Creating welcome model" || result=1
    teardown
    return $result
}
test_lxd_skip_existing_controller; report "LXD: skips bootstrap when controller exists" $?

test_lxd_skip_existing_model() {
    setup
    make_sockets_writable
    patch_wrapper_with_real_bootstrap_lxd
    MOCK_HAS_MODEL=1 run_patched deploy postgresql
    result=0
    assert_stderr_contains "Bootstrapping" || result=1
    assert_stderr_not_contains "Creating welcome model" || result=1
    teardown
    return $result
}
test_lxd_skip_existing_model; report "LXD: skips add-model when model exists" $?

echo ""
echo "=== Bootstrap idempotency (K8s) ==="

test_k8s_missing_kubeconfig() {
    setup
    make_sockets_writable
    patch_wrapper_with_real_bootstrap_lxd
    # Do NOT create the kubeconfig file
    run_patched deploy postgresql-k8s --trust
    result=0
    [ "$LAST_RC" -ne 0 ] || { echo "  ASSERT FAILED: expected non-zero exit"; result=1; }
    assert_stderr_contains "kubeconfig not found" || result=1
    teardown
    return $result
}
test_k8s_missing_kubeconfig; report "K8s: error when kubeconfig missing" $?

test_k8s_kubeconfig_backup() {
    setup
    make_sockets_writable
    patch_wrapper_with_real_bootstrap_lxd
    # Redirect HOME to test dir so ~/.kube is under our control
    sed -i "s|\${HOME}|${TEST_DIR}/home|g" "${PATCHED}"
    mkdir -p "${TEST_DIR}/home/.kube"
    echo "old-config" > "${TEST_DIR}/home/.kube/config"
    echo "fake-kubeconfig" > "${TEST_DIR}/kubeconfig"
    MOCK_HAS_K8S_CLOUD=1 MOCK_HAS_K8S_CONTROLLER=1 MOCK_HAS_MODEL=1 \
        run_patched deploy postgresql-k8s --trust
    result=0
    [ -f "${TEST_DIR}/home/.kube/config.bak" ] || { echo "  ASSERT FAILED: config.bak not created"; result=1; }
    grep -q "old-config" "${TEST_DIR}/home/.kube/config.bak" 2>/dev/null || { echo "  ASSERT FAILED: config.bak has wrong content"; result=1; }
    grep -q "fake-kubeconfig" "${TEST_DIR}/home/.kube/config" 2>/dev/null || { echo "  ASSERT FAILED: config not updated"; result=1; }
    teardown
    return $result
}
test_k8s_kubeconfig_backup; report "K8s: backs up existing kubeconfig" $?

test_k8s_skip_existing_cloud() {
    setup
    make_sockets_writable
    patch_wrapper_with_real_bootstrap_lxd
    echo "fake-kubeconfig" > "${TEST_DIR}/kubeconfig"
    sed -i "s|\${HOME}|${TEST_DIR}/home|g" "${PATCHED}"
    mkdir -p "${TEST_DIR}/home/.kube"
    MOCK_HAS_K8S_CLOUD=1 run_patched deploy postgresql-k8s --trust
    result=0
    assert_stderr_not_contains "Registering" || result=1
    assert_stderr_contains "Bootstrapping" || result=1
    teardown
    return $result
}
test_k8s_skip_existing_cloud; report "K8s: skips add-k8s when cloud exists" $?

# ============================================================
# Protocol streaming (real socket, real relay_progress)
# ============================================================

# `func; report ... $?` would exit on a failing test under set -e. The
# if/else form below is exempt from set -e, so a failing protocol test
# still reports and the section continues.
run_proto_test() {
    _proto_name="$1"
    shift
    if "$@"; then report "$_proto_name" 0; else report "$_proto_name" $?; fi
}

echo ""
echo "=== Protocol streaming ==="

# Spawns a Unix socket listener that:
#   - signals readiness via $READY file (avoids connect() race)
#   - accepts ONE connection
#   - eats the mode byte
#   - if SNAP_CREATE_PATH set, drops a fake juju snap (so wait_for_snap passes)
#   - replays each line of $script_file followed by \n
#   - "__CLOSE__" closes without sending more (simulates abnormal exit)
start_mock_service() {
    SOCK="$1"
    SCRIPT="$2"
    READY="${TEST_DIR}/mock-ready"
    rm -f "$READY"
    SOCK="$SOCK" SCRIPT="$SCRIPT" READY="$READY" \
        SNAP_CREATE_PATH="${SNAP_CREATE_PATH:-}" python3 -c '
import os, socket
sock_path = os.environ["SOCK"]
script = os.environ["SCRIPT"]
ready = os.environ["READY"]
snap_path = os.environ.get("SNAP_CREATE_PATH", "")
try: os.unlink(sock_path)
except FileNotFoundError: pass
srv = socket.socket(socket.AF_UNIX); srv.bind(sock_path); srv.listen(1)
os.chmod(sock_path, 0o660)
open(ready, "w").close()
conn, _ = srv.accept()
conn.recv(1)
if snap_path:
    os.makedirs(os.path.dirname(snap_path), exist_ok=True)
    with open(snap_path, "w") as f:
        f.write("#!/bin/sh\necho mock-juju \"$@\"\n")
    os.chmod(snap_path, 0o755)
with open(script) as f:
    for line in f:
        line = line.rstrip("\n")
        if line == "__CLOSE__": break
        conn.sendall((line + "\n").encode())
conn.close(); srv.close()
' &
    MOCK_PID=$!
    i=0
    while [ ! -f "$READY" ] && [ "$i" -lt 50 ]; do
        sleep 0.1
        i=$((i + 1))
    done
}

stop_mock_service() {
    if [ -n "${MOCK_PID:-}" ]; then
        kill "$MOCK_PID" 2>/dev/null || true
        wait "$MOCK_PID" 2>/dev/null || true
        MOCK_PID=
    fi
}

# Like patch_wrapper but does NOT stub trigger_*_service — exercises real relay_progress.
patch_wrapper_with_real_relay() {
    make_sockets_writable
    PATCHED="${TEST_DIR}/wrapper.sh"
    sed \
        -e "s|SNAP_BIN=\"/snap/bin/juju\"|SNAP_BIN=\"${FAKE_SNAP_BIN}\"|" \
        -e "s|/run/juju-installer-snap.socket|${FAKE_SNAP_SOCKET}|g" \
        -e "s|/run/juju-installer-lxd.socket|${FAKE_LXD_SOCKET}|g" \
        -e "s|/run/juju-installer-k8s.socket|${FAKE_K8S_SOCKET}|g" \
        -e "s|/proc/self/cgroup|${FAKE_CGROUP}|g" \
        "${WRAPPER}" > "${PATCHED}"
    sed -i 's/read -r answer < \/dev\/tty || answer="y"/answer="y"/' "${PATCHED}"
    sed -i "/^wait_for_snap() {/,/^}/ { s/sleep 1/sleep 0/; }" "${PATCHED}"
    sed -i "/^has_lxd_controller() {/,/^}/c\\
has_lxd_controller() { [ \"\${MOCK_HAS_LXD_CONTROLLER:-0}\" -eq 1 ]; }" "${PATCHED}"
    sed -i "/^has_k8s_cloud() {/,/^}/c\\
has_k8s_cloud() { [ \"\${MOCK_HAS_K8S_CLOUD:-0}\" -eq 1 ]; }" "${PATCHED}"
    sed -i "/^has_k8s_controller() {/,/^}/c\\
has_k8s_controller() { [ \"\${MOCK_HAS_K8S_CONTROLLER:-0}\" -eq 1 ]; }" "${PATCHED}"
    sed -i "/^has_model() {/,/^}/c\\
has_model() { [ \"\${MOCK_HAS_MODEL:-0}\" -eq 1 ]; }" "${PATCHED}"
    sed -i "/^do_bootstrap_lxd() {/,/^}/c\\
do_bootstrap_lxd() { BOOTSTRAPPED=1; }" "${PATCHED}"
    sed -i "/^do_bootstrap_k8s() {/,/^}/c\\
do_bootstrap_k8s() { BOOTSTRAPPED=1; }" "${PATCHED}"
    chmod +x "${PATCHED}"
}

test_k8s_streams_all_steps() {
    setup
    SCRIPT="${TEST_DIR}/script"
    cat > "$SCRIPT" <<EOF
[2/9] Installing Juju snap...
[3/9] Installing Canonical K8s...
[4/9] Bootstrapping Canonical K8s...
[5/9] Waiting for K8s to be ready...
[6/9] Enabling local-storage...
[7/9] Exporting kubeconfig...
1
EOF
    SNAP_CREATE_PATH="${FAKE_SNAP_BIN}" start_mock_service "${FAKE_K8S_SOCKET}" "$SCRIPT"
    patch_wrapper_with_real_relay
    run_patched deploy postgresql-k8s --trust
    result=0
    for n in 2 3 4 5 6 7; do
        assert_stderr_contains "\[${n}/9\]" || result=1
    done
    stop_mock_service
    teardown
    return $result
}
run_proto_test "relay: K8s streams [2/9]..[7/9] from service" test_k8s_streams_all_steps

test_k8s_handles_clean_terminator() {
    setup
    SCRIPT="${TEST_DIR}/script"
    printf '[2/9] foo\n1\n' > "$SCRIPT"
    SNAP_CREATE_PATH="${FAKE_SNAP_BIN}" start_mock_service "${FAKE_K8S_SOCKET}" "$SCRIPT"
    patch_wrapper_with_real_relay
    run_patched deploy postgresql-k8s --trust
    result=0
    [ "$LAST_RC" -eq 0 ] || { echo "  ASSERT FAILED: expected exit 0, got $LAST_RC"; result=1; }
    stop_mock_service
    teardown
    return $result
}
run_proto_test "relay: clean terminator → exit 0, bootstrap continues" test_k8s_handles_clean_terminator

test_relay_eof_without_terminator() {
    setup
    SCRIPT="${TEST_DIR}/script"
    printf '[2/9] foo\n__CLOSE__\n' > "$SCRIPT"
    start_mock_service "${FAKE_K8S_SOCKET}" "$SCRIPT"
    patch_wrapper_with_real_relay
    run_patched deploy postgresql-k8s --trust
    result=0
    [ "$LAST_RC" -ne 0 ] || { echo "  ASSERT FAILED: expected non-zero exit"; result=1; }
    assert_stderr_contains "exited unexpectedly" || result=1
    assert_stderr_contains "journalctl" || result=1
    stop_mock_service
    teardown
    return $result
}
run_proto_test "relay: EOF without terminator → ERROR" test_relay_eof_without_terminator

test_relay_socket_missing() {
    setup
    # Regular file passes check_socket_access; relay_progress connect() will refuse.
    make_sockets_writable
    patch_wrapper_with_real_relay
    run_patched deploy postgresql-k8s --trust
    result=0
    [ "$LAST_RC" -ne 0 ] || { echo "  ASSERT FAILED: expected non-zero exit"; result=1; }
    assert_stderr_contains "cannot reach" || result=1
    teardown
    return $result
}
run_proto_test "relay: unreachable socket → ERROR" test_relay_socket_missing

test_service_error_line_relayed() {
    setup
    SCRIPT="${TEST_DIR}/script"
    printf 'ERROR: snap install failed\n__CLOSE__\n' > "$SCRIPT"
    start_mock_service "${FAKE_K8S_SOCKET}" "$SCRIPT"
    patch_wrapper_with_real_relay
    run_patched deploy postgresql-k8s --trust
    result=0
    [ "$LAST_RC" -ne 0 ] || { echo "  ASSERT FAILED: expected non-zero exit"; result=1; }
    assert_stderr_contains "snap install failed" || result=1
    assert_stderr_contains "exited unexpectedly" || result=1
    stop_mock_service
    teardown
    return $result
}
run_proto_test "relay: service ERROR + EOF tail both shown" test_service_error_line_relayed

test_lxd_streams_all_steps() {
    setup
    SCRIPT="${TEST_DIR}/script"
    printf '[2/5] Installing Juju snap...\n[3/5] Installing LXD...\n1\n' > "$SCRIPT"
    SNAP_CREATE_PATH="${FAKE_SNAP_BIN}" start_mock_service "${FAKE_LXD_SOCKET}" "$SCRIPT"
    patch_wrapper_with_real_relay
    run_patched deploy postgresql
    result=0
    assert_stderr_contains "\[2/5\]" || result=1
    assert_stderr_contains "\[3/5\]" || result=1
    stop_mock_service
    teardown
    return $result
}
run_proto_test "relay: LXD streams [2/5]..[3/5] from service" test_lxd_streams_all_steps

test_snap_only_streams() {
    setup
    SCRIPT="${TEST_DIR}/script"
    printf '[1/1] Installing Juju snap...\n1\n' > "$SCRIPT"
    SNAP_CREATE_PATH="${FAKE_SNAP_BIN}" start_mock_service "${FAKE_SNAP_SOCKET}" "$SCRIPT"
    patch_wrapper_with_real_relay
    run_patched version
    result=0
    assert_stderr_contains "\[1/1\]" || result=1
    stop_mock_service
    teardown
    return $result
}
run_proto_test "relay: snap-only streams [1/1] from service" test_snap_only_streams

test_k8s_8_9_label_shared() {
    setup
    SCRIPT="${TEST_DIR}/script"
    printf '1\n' > "$SCRIPT"
    SNAP_CREATE_PATH="${FAKE_SNAP_BIN}" start_mock_service "${FAKE_K8S_SOCKET}" "$SCRIPT"
    make_sockets_writable
    PATCHED="${TEST_DIR}/wrapper.sh"
    # Same as patch_wrapper_with_real_relay but keep real do_bootstrap_k8s so we can
    # observe the [8/9] reuse for cloud-register and controller-bootstrap.
    sed \
        -e "s|SNAP_BIN=\"/snap/bin/juju\"|SNAP_BIN=\"${FAKE_SNAP_BIN}\"|" \
        -e "s|/run/juju-installer-snap.socket|${FAKE_SNAP_SOCKET}|g" \
        -e "s|/run/juju-installer-lxd.socket|${FAKE_LXD_SOCKET}|g" \
        -e "s|/run/juju-installer-k8s.socket|${FAKE_K8S_SOCKET}|g" \
        -e "s|/proc/self/cgroup|${FAKE_CGROUP}|g" \
        -e "s|/run/juju-installer-k8s-kubeconfig|${TEST_DIR}/kubeconfig|g" \
        "${WRAPPER}" > "${PATCHED}"
    sed -i 's/read -r answer < \/dev\/tty || answer="y"/answer="y"/' "${PATCHED}"
    sed -i "/^wait_for_snap() {/,/^}/ { s/sleep 1/sleep 0/; }" "${PATCHED}"
    sed -i "/^has_k8s_cloud() {/,/^}/c\\
has_k8s_cloud() { false; }" "${PATCHED}"
    sed -i "/^has_k8s_controller() {/,/^}/c\\
has_k8s_controller() { false; }" "${PATCHED}"
    sed -i "/^has_model() {/,/^}/c\\
has_model() { false; }" "${PATCHED}"
    sed -i "s|\${HOME}|${TEST_DIR}/home|g" "${PATCHED}"
    mkdir -p "${TEST_DIR}/home/.kube"
    echo "fake-kubeconfig" > "${TEST_DIR}/kubeconfig"
    chmod +x "${PATCHED}"
    run_patched deploy postgresql-k8s --trust
    result=0
    assert_stderr_contains "\[8/9\] Registering" || result=1
    assert_stderr_contains "\[8/9\] Bootstrapping" || result=1
    assert_stderr_contains "\[9/9\] Creating welcome model" || result=1
    stop_mock_service
    teardown
    return $result
}
run_proto_test "K8s: [8/9] label shared between cloud-register and bootstrap" test_k8s_8_9_label_shared

# ============================================================
# Summary
# ============================================================

echo ""
echo "=== Results: ${PASS}/${TOTAL} passed, ${FAIL} failed ==="
[ "$FAIL" -eq 0 ] || exit 1
