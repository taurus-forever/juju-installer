#!/bin/sh
# Unit tests for service scripts (share/*).
# Run: sh tests/test_services.sh
#
# These tests mock snap/lxd/k8s binaries and pipe a mode byte to stdin
# to simulate the systemd socket protocol.
set -eu

SHARE_DIR="$(cd "$(dirname "$0")/.." && pwd)/share"
PASS=0
FAIL=0
TOTAL=0

setup() {
    TEST_DIR=$(mktemp -d)
    FAKE_BIN="${TEST_DIR}/bin"
    mkdir -p "${FAKE_BIN}"
    CALL_LOG="${TEST_DIR}/calls.log"
    : > "${CALL_LOG}"
}

teardown() {
    rm -rf "${TEST_DIR}"
}

make_fake_bin() {
    name="$1"
    shift
    # Default: log call and exit 0
    printf '#!/bin/sh\necho "%s $@" >> "%s"\n' "$name" "${CALL_LOG}" \
        > "${FAKE_BIN}/${name}"
    # Append any extra lines
    for line in "$@"; do
        echo "$line" >> "${FAKE_BIN}/${name}"
    done
    chmod +x "${FAKE_BIN}/${name}"
}

patch_service() {
    script="$1"
    PATCHED="${TEST_DIR}/service.sh"
    cp "${SHARE_DIR}/${script}" "${PATCHED}"
    # Replace /snap/bin/* with our fake bin dir
    sed -i "s|/snap/bin/|${FAKE_BIN}/|g" "${PATCHED}"
    # Replace snap command (used for snap install)
    sed -i "s|snap install|${FAKE_BIN}/snap install|g" "${PATCHED}"
    # Replace lxd-installer socket path
    sed -i "s|/run/lxd-installer.socket|${TEST_DIR}/lxd-installer.socket|g" "${PATCHED}"
    # Replace kubeconfig output path
    sed -i "s|/run/juju-installer-k8s-kubeconfig|${TEST_DIR}/kubeconfig|g" "${PATCHED}"
    # Replace chgrp (may fail without lxd group)
    sed -i "s|chgrp lxd|echo chgrp-lxd >>\"${CALL_LOG}\" #|g" "${PATCHED}"
    # Speed up any wait loops
    sed -i 's/sleep [0-9]*/sleep 0/g' "${PATCHED}"
    chmod +x "${PATCHED}"
}

run_service() {
    set +e
    echo "i" | sh "${PATCHED}" >"${TEST_DIR}/stdout" 2>"${TEST_DIR}/stderr"
    LAST_RC=$?
    set -e
}

assert_call_log_contains() {
    if ! grep -q "$1" "${CALL_LOG}" 2>/dev/null; then
        echo "  ASSERT FAILED: call log does not contain '$1'"
        echo "  calls were: $(cat "${CALL_LOG}" 2>/dev/null)"
        return 1
    fi
    return 0
}

assert_call_log_not_contains() {
    if grep -q "$1" "${CALL_LOG}" 2>/dev/null; then
        echo "  ASSERT FAILED: call log should not contain '$1'"
        echo "  calls were: $(cat "${CALL_LOG}" 2>/dev/null)"
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

assert_stderr_contains() {
    if ! grep -q "$1" "${TEST_DIR}/stderr" 2>/dev/null; then
        echo "  ASSERT FAILED: stderr does not contain '$1'"
        echo "  stderr was: $(cat "${TEST_DIR}/stderr" 2>/dev/null)"
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

# set -e + run_service's internal set -e together cause "func; report ... $?"
# to exit on first failing test. The if/else form is exempt from set -e.
# Use _proto_name (not name) — POSIX sh has no `local`, and several helpers
# (make_fake_bin, patch_service) overwrite a plain `name` variable.
run_test() {
    _proto_name="$1"
    shift
    if "$@"; then report "$_proto_name" 0; else report "$_proto_name" $?; fi
}

# ============================================================
# Snap service tests
# ============================================================

echo "=== Snap service ==="

test_snap_full_install() {
    setup
    make_fake_bin "snap"
    patch_service "juju-installer-snap-service"
    run_service
    result=0
    assert_call_log_contains "snap install juju" || result=1
    assert_stdout_contains "1" || result=1
    [ "$LAST_RC" -eq 0 ] || { echo "  ASSERT FAILED: expected exit 0, got $LAST_RC"; result=1; }
    teardown
    return $result
}
test_snap_full_install; report "snap: installs juju when missing" $?

test_snap_already_installed() {
    setup
    make_fake_bin "snap"
    make_fake_bin "juju"
    patch_service "juju-installer-snap-service"
    run_service
    result=0
    assert_call_log_not_contains "snap install" || result=1
    assert_stdout_contains "1" || result=1
    teardown
    return $result
}
test_snap_already_installed; report "snap: skips install when juju exists" $?

test_snap_signal_protocol() {
    setup
    make_fake_bin "snap"
    patch_service "juju-installer-snap-service"
    run_service
    result=0
    last_line=$(tail -n 1 "${TEST_DIR}/stdout")
    [ "$last_line" = "1" ] || { echo "  ASSERT FAILED: expected last stdout line '1', got '${last_line}'"; result=1; }
    teardown
    return $result
}
run_test "snap: terminator '1' is the final stdout line" test_snap_signal_protocol

test_snap_progress_on_stdout() {
    setup
    make_fake_bin "snap"
    patch_service "juju-installer-snap-service"
    run_service
    result=0
    assert_stdout_contains "\[1/1\] Installing Juju snap" || result=1
    # Tool chatter (snap install ...) must not leak onto stdout (= socket)
    if grep -q "snap install" "${TEST_DIR}/stdout"; then
        echo "  ASSERT FAILED: 'snap install' chatter leaked to stdout"
        result=1
    fi
    teardown
    return $result
}
run_test "snap: [1/1] on stdout, no chatter leak" test_snap_progress_on_stdout

# ============================================================
# LXD service tests
# ============================================================

echo ""
echo "=== LXD service ==="

test_lxd_full_install() {
    setup
    make_fake_bin "snap"
    # lxc storage list returns nothing (no default pool)
    make_fake_bin "lxc" 'echo ""'
    make_fake_bin "lxd"
    patch_service "juju-installer-lxd-service"
    # Stub the lxd-installer socket trigger (python3 call)
    sed -i "/python3 -c/c\\    ${FAKE_BIN}/snap install-lxd-stub" "${PATCHED}"
    # Make lxd appear after trigger
    sed -i "s|${FAKE_BIN}/snap install-lxd-stub|${FAKE_BIN}/snap install-lxd-stub; ln -sf /bin/true ${FAKE_BIN}/lxd|" "${PATCHED}"
    run_service
    result=0
    assert_call_log_contains "snap install juju" || result=1
    assert_stdout_contains "\[2/5\] Installing Juju" || result=1
    assert_stdout_contains "1" || result=1
    teardown
    return $result
}
run_test "lxd: full install path" test_lxd_full_install

test_lxd_snap_exists() {
    setup
    make_fake_bin "snap"
    make_fake_bin "juju"
    make_fake_bin "lxd"
    # lxc storage list returns default pool
    make_fake_bin "lxc" 'echo "default,dir,/var/snap/lxd/common/lxd/storage-pools/default,created"'
    patch_service "juju-installer-lxd-service"
    run_service
    result=0
    assert_call_log_not_contains "snap install juju" || result=1
    assert_stdout_contains "1" || result=1
    teardown
    return $result
}
test_lxd_snap_exists; report "lxd: skips juju install when present" $?

test_lxd_already_initialized() {
    setup
    make_fake_bin "snap"
    make_fake_bin "juju"
    make_fake_bin "lxd"
    # lxc storage list returns default pool
    make_fake_bin "lxc" 'echo "default,dir,/var/snap/lxd/common/lxd/storage-pools/default,created"'
    patch_service "juju-installer-lxd-service"
    run_service
    result=0
    assert_call_log_not_contains "lxd init" || result=1
    assert_stdout_contains "1" || result=1
    teardown
    return $result
}
test_lxd_already_initialized; report "lxd: skips init when already initialized" $?

test_lxd_install_timeout() {
    setup
    make_fake_bin "snap"
    make_fake_bin "juju"
    # No lxd binary — will timeout
    patch_service "juju-installer-lxd-service"
    # Stub python3 socket trigger to no-op
    sed -i "/python3 -c/c\\    true" "${PATCHED}"
    # Reduce timeout to 1 iteration
    sed -i 's/while \[ "\$i" -lt 90 \]/while [ "$i" -lt 1 ]/' "${PATCHED}"
    run_service
    result=0
    [ "$LAST_RC" -ne 0 ] || { echo "  ASSERT FAILED: expected non-zero exit"; result=1; }
    assert_stdout_contains "timed out" || result=1
    teardown
    return $result
}
run_test "lxd: timeout when lxd never appears" test_lxd_install_timeout

test_lxd_idempotent() {
    setup
    make_fake_bin "snap"
    make_fake_bin "juju"
    make_fake_bin "lxd"
    # lxc storage list returns default pool
    make_fake_bin "lxc" 'echo "default,dir,/var/snap/lxd/common/lxd/storage-pools/default,created"'
    patch_service "juju-installer-lxd-service"
    run_service
    result=0
    assert_call_log_not_contains "snap install" || result=1
    assert_call_log_not_contains "lxd init" || result=1
    assert_stdout_contains "1" || result=1
    teardown
    return $result
}
test_lxd_idempotent; report "lxd: idempotent when everything set up" $?

# ============================================================
# K8s service tests
# ============================================================

echo ""
echo "=== K8s service ==="

make_k8s_fake() {
    # Creates a k8s fake that simulates bootstrap-then-ready lifecycle
    printf '#!/bin/sh\necho "k8s $@" >> "%s"\n' "${CALL_LOG}" > "${FAKE_BIN}/k8s"
    cat >> "${FAKE_BIN}/k8s" << 'FAKEOF'
case "$1" in
    status)
        if [ -f "$0.bootstrapped" ]; then
            echo "cluster status:  ready"
            echo "local-storage    enabled"
            exit 0
        fi
        exit 1
        ;;
    bootstrap)
        touch "$0.bootstrapped"
        ;;
    config)
        echo "fake-kubeconfig-data"
        ;;
    enable)
        ;;
esac
FAKEOF
    chmod +x "${FAKE_BIN}/k8s"
}

make_k8s_fake_ready() {
    # Creates a k8s fake that is already bootstrapped and ready
    printf '#!/bin/sh\necho "k8s $@" >> "%s"\n' "${CALL_LOG}" > "${FAKE_BIN}/k8s"
    cat >> "${FAKE_BIN}/k8s" << 'FAKEOF'
case "$1" in
    status) echo "cluster status:  ready"; echo "local-storage    enabled"; exit 0 ;;
    config) echo "fake-kubeconfig-data" ;;
esac
FAKEOF
    chmod +x "${FAKE_BIN}/k8s"
}

make_snap_installer() {
    # Creates a snap fake that logs and creates binaries on install
    _k8s_fake_path="${FAKE_BIN}/k8s"
    cat > "${FAKE_BIN}/snap" << SNAPEOF
#!/bin/sh
echo "snap \$@" >> "${CALL_LOG}"
case "\$2" in
    juju) ln -sf /bin/true "${FAKE_BIN}/juju" ;;
    k8s) ;;
esac
SNAPEOF
    chmod +x "${FAKE_BIN}/snap"
}

test_k8s_full_install() {
    setup
    # Write the k8s fake to a staging path (not FAKE_BIN) so -x check fails
    K8S_STAGED="${TEST_DIR}/k8s_staged"
    printf '#!/bin/sh\necho "k8s $@" >> "%s"\n' "${CALL_LOG}" > "${K8S_STAGED}"
    cat >> "${K8S_STAGED}" << 'FAKEOF'
case "$1" in
    status)
        if [ -f "$0.bootstrapped" ]; then
            echo "cluster status:  ready"
            echo "local-storage    enabled"
            exit 0
        fi
        exit 1
        ;;
    bootstrap) touch "$0.bootstrapped" ;;
    config) echo "fake-kubeconfig-data" ;;
    enable) ;;
esac
FAKEOF
    chmod +x "${K8S_STAGED}"
    # snap install copies staged binaries into FAKE_BIN
    cat > "${FAKE_BIN}/snap" << SNAPEOF
#!/bin/sh
echo "snap \$@" >> "${CALL_LOG}"
case "\$2" in
    juju) ln -sf /bin/true "${FAKE_BIN}/juju" ;;
    k8s) cp "${K8S_STAGED}" "${FAKE_BIN}/k8s"; chmod +x "${FAKE_BIN}/k8s" ;;
esac
SNAPEOF
    chmod +x "${FAKE_BIN}/snap"
    patch_service "juju-installer-k8s-service"
    run_service
    result=0
    assert_call_log_contains "snap install juju" || result=1
    assert_call_log_contains "snap install k8s" || result=1
    assert_call_log_contains "k8s bootstrap" || result=1
    [ -f "${TEST_DIR}/kubeconfig" ] || { echo "  ASSERT FAILED: kubeconfig not created"; result=1; }
    assert_stdout_contains "1" || result=1
    teardown
    return $result
}
test_k8s_full_install; report "k8s: full install path" $?

test_k8s_snap_exists() {
    setup
    make_fake_bin "snap"
    make_fake_bin "juju"
    make_k8s_fake_ready
    patch_service "juju-installer-k8s-service"
    run_service
    result=0
    assert_call_log_not_contains "snap install k8s" || result=1
    assert_stdout_contains "1" || result=1
    teardown
    return $result
}
test_k8s_snap_exists; report "k8s: skips install when k8s snap exists" $?

test_k8s_already_bootstrapped() {
    setup
    make_fake_bin "snap"
    make_fake_bin "juju"
    make_k8s_fake_ready
    patch_service "juju-installer-k8s-service"
    run_service
    result=0
    assert_call_log_not_contains "k8s bootstrap" || result=1
    assert_stdout_contains "1" || result=1
    teardown
    return $result
}
test_k8s_already_bootstrapped; report "k8s: skips bootstrap when already running" $?

test_k8s_not_ready_timeout() {
    setup
    make_fake_bin "snap"
    make_fake_bin "juju"
    # k8s: plain status succeeds (bootstrapped) but --wait-ready fails
    printf '#!/bin/sh\necho "k8s $@" >> "%s"\n' "${CALL_LOG}" > "${FAKE_BIN}/k8s"
    cat >> "${FAKE_BIN}/k8s" << 'FAKEOF'
case "$*" in
    *--wait-ready*) exit 1 ;;
    status*) echo "cluster status:  bootstrapping"; exit 0 ;;
esac
FAKEOF
    chmod +x "${FAKE_BIN}/k8s"
    patch_service "juju-installer-k8s-service"
    # Reduce wait loop to 1 iteration
    sed -i 's/while \[ "\$i" -lt 60 \]/while [ "$i" -lt 1 ]/' "${PATCHED}"
    run_service
    result=0
    [ "$LAST_RC" -ne 0 ] || { echo "  ASSERT FAILED: expected non-zero exit"; result=1; }
    assert_stdout_contains "did not become ready" || result=1
    teardown
    return $result
}
run_test "k8s: timeout when cluster not ready" test_k8s_not_ready_timeout

test_k8s_storage_already_enabled() {
    setup
    make_fake_bin "snap"
    make_fake_bin "juju"
    make_k8s_fake_ready
    patch_service "juju-installer-k8s-service"
    run_service
    result=0
    assert_call_log_not_contains "k8s enable" || result=1
    assert_stdout_contains "1" || result=1
    teardown
    return $result
}
test_k8s_storage_already_enabled; report "k8s: skips enable when storage enabled" $?

test_k8s_kubeconfig_permissions() {
    setup
    make_fake_bin "snap"
    make_fake_bin "juju"
    make_k8s_fake_ready
    patch_service "juju-installer-k8s-service"
    run_service
    result=0
    [ -f "${TEST_DIR}/kubeconfig" ] || { echo "  ASSERT FAILED: kubeconfig not created"; result=1; }
    perms=$(stat -c '%a' "${TEST_DIR}/kubeconfig" 2>/dev/null)
    [ "$perms" = "640" ] || { echo "  ASSERT FAILED: expected mode 640, got ${perms}"; result=1; }
    teardown
    return $result
}
test_k8s_kubeconfig_permissions; report "k8s: kubeconfig has mode 0640" $?

test_k8s_idempotent() {
    setup
    make_fake_bin "snap"
    make_fake_bin "juju"
    make_k8s_fake_ready
    patch_service "juju-installer-k8s-service"
    run_service
    result=0
    assert_call_log_not_contains "snap install" || result=1
    assert_call_log_not_contains "k8s bootstrap" || result=1
    assert_call_log_not_contains "k8s enable" || result=1
    assert_call_log_contains "k8s config" || result=1
    assert_stdout_contains "1" || result=1
    teardown
    return $result
}
test_k8s_idempotent; report "k8s: idempotent, only exports kubeconfig" $?

echo ""
echo "=== Service stdout protocol (Layer 3) ==="

test_k8s_progress_on_stdout() {
    setup
    K8S_STAGED="${TEST_DIR}/k8s_staged"
    printf '#!/bin/sh\necho "k8s $@" >> "%s"\n' "${CALL_LOG}" > "${K8S_STAGED}"
    cat >> "${K8S_STAGED}" << 'FAKEOF'
case "$1" in
    status)
        if [ -f "$0.bootstrapped" ]; then
            echo "cluster status:  ready"
            [ -f "$0.storage" ] && echo "local-storage    enabled"
            exit 0
        fi
        exit 1
        ;;
    bootstrap) touch "$0.bootstrapped" ;;
    config) echo "fake-kubeconfig-data" ;;
    enable) touch "$0.storage" ;;
esac
FAKEOF
    chmod +x "${K8S_STAGED}"
    cat > "${FAKE_BIN}/snap" << SNAPEOF
#!/bin/sh
echo "snap \$@" >> "${CALL_LOG}"
case "\$2" in
    juju) ln -sf /bin/true "${FAKE_BIN}/juju" ;;
    k8s) cp "${K8S_STAGED}" "${FAKE_BIN}/k8s"; chmod +x "${FAKE_BIN}/k8s" ;;
esac
SNAPEOF
    chmod +x "${FAKE_BIN}/snap"
    patch_service "juju-installer-k8s-service"
    run_service
    result=0
    for n in 2 3 4 5 6 7; do
        assert_stdout_contains "\[${n}/9\]" || result=1
    done
    last_line=$(tail -n 1 "${TEST_DIR}/stdout")
    [ "$last_line" = "1" ] || { echo "  ASSERT FAILED: expected last stdout line '1', got '${last_line}'"; result=1; }
    if grep -q "snap install" "${TEST_DIR}/stdout"; then
        echo "  ASSERT FAILED: 'snap install' chatter leaked to stdout"
        result=1
    fi
    if grep -q "k8s bootstrap" "${TEST_DIR}/stdout"; then
        echo "  ASSERT FAILED: 'k8s bootstrap' chatter leaked to stdout"
        result=1
    fi
    teardown
    return $result
}
run_test "k8s: [2/9]..[7/9] on stdout, terminator last, no chatter leak" test_k8s_progress_on_stdout

test_lxd_progress_on_stdout() {
    setup
    make_fake_bin "snap"
    make_fake_bin "lxc" 'echo ""'
    make_fake_bin "lxd"
    patch_service "juju-installer-lxd-service"
    sed -i "/python3 -c/c\\    ${FAKE_BIN}/snap install-lxd-stub" "${PATCHED}"
    sed -i "s|${FAKE_BIN}/snap install-lxd-stub|${FAKE_BIN}/snap install-lxd-stub; ln -sf /bin/true ${FAKE_BIN}/lxd|" "${PATCHED}"
    run_service
    result=0
    assert_stdout_contains "\[2/5\] Installing Juju" || result=1
    assert_stdout_contains "\[3/5\]" || result=1
    last_line=$(tail -n 1 "${TEST_DIR}/stdout")
    [ "$last_line" = "1" ] || { echo "  ASSERT FAILED: expected last stdout line '1', got '${last_line}'"; result=1; }
    if grep -q "snap install" "${TEST_DIR}/stdout"; then
        echo "  ASSERT FAILED: 'snap install' chatter leaked to stdout"
        result=1
    fi
    if grep -q "lxd init" "${TEST_DIR}/stdout"; then
        echo "  ASSERT FAILED: 'lxd init' chatter leaked to stdout"
        result=1
    fi
    teardown
    return $result
}
run_test "lxd: [2/5]..[3/5] on stdout, terminator last, no chatter leak" test_lxd_progress_on_stdout

# ============================================================
# Summary
# ============================================================

echo ""
echo "=== Results: ${PASS}/${TOTAL} passed, ${FAIL} failed ==="
[ "$FAIL" -eq 0 ] || exit 1
