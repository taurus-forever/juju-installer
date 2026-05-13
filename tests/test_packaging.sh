#!/bin/sh
# Structural validation tests for systemd units and debian packaging.
# Run: sh tests/test_packaging.sh
#
# These are static checks on repository files. No mocking needed.
set -eu

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0
FAIL=0
TOTAL=0

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
# Systemd unit validation
# ============================================================

echo "=== Systemd units ==="

test_systemd_units_parse() {
    if ! command -v systemd-analyze >/dev/null 2>&1; then
        echo "  SKIP: systemd-analyze not available"
        return 0
    fi
    result=0
    for unit in "${REPO_DIR}"/systemd/*; do
        if ! systemd-analyze verify "$unit" 2>/dev/null; then
            echo "  ASSERT FAILED: $unit does not parse"
            result=1
        fi
    done
    return $result
}
test_systemd_units_parse; report "systemd units parse" $?

test_socket_paths_match_code() {
    result=0
    for socket_file in "${REPO_DIR}"/systemd/*.socket; do
        socket_path=$(grep '^ListenStream=' "$socket_file" | cut -d= -f2)
        basename=$(basename "$socket_file" .socket)
        if ! grep -q "$socket_path" "${REPO_DIR}/sbin/juju"; then
            echo "  ASSERT FAILED: $socket_path (from $basename.socket) not found in sbin/juju"
            result=1
        fi
    done
    return $result
}
test_socket_paths_match_code; report "socket paths match wrapper code" $?

test_socket_group_lxd() {
    result=0
    for socket_file in "${REPO_DIR}"/systemd/*.socket; do
        if ! grep -q 'SocketGroup=lxd' "$socket_file"; then
            echo "  ASSERT FAILED: $(basename "$socket_file") missing SocketGroup=lxd"
            result=1
        fi
    done
    return $result
}
test_socket_group_lxd; report "all sockets use group lxd" $?

test_socket_accept_true() {
    result=0
    for socket_file in "${REPO_DIR}"/systemd/*.socket; do
        if ! grep -q 'Accept=true' "$socket_file"; then
            echo "  ASSERT FAILED: $(basename "$socket_file") missing Accept=true"
            result=1
        fi
    done
    return $result
}
test_socket_accept_true; report "all sockets have Accept=true" $?

# ============================================================
# Debian packaging validation
# ============================================================

echo ""
echo "=== Debian packaging ==="

test_install_covers_all_files() {
    result=0
    for dir in sbin share systemd; do
        for file in "${REPO_DIR}/${dir}"/*; do
            [ -f "$file" ] || continue
            relpath="${dir}/$(basename "$file")"
            if ! grep -q "^${relpath}" "${REPO_DIR}/debian/install"; then
                echo "  ASSERT FAILED: ${relpath} not listed in debian/install"
                result=1
            fi
        done
    done
    return $result
}
test_install_covers_all_files; report "debian/install covers all shipped files" $?

test_no_stale_install_entries() {
    result=0
    while IFS= read -r line; do
        # Skip empty lines and comments
        case "$line" in
            ''|\#*) continue ;;
        esac
        src=$(echo "$line" | awk '{print $1}')
        if [ ! -f "${REPO_DIR}/${src}" ]; then
            echo "  ASSERT FAILED: ${src} listed in debian/install but does not exist"
            result=1
        fi
    done < "${REPO_DIR}/debian/install"
    return $result
}
test_no_stale_install_entries; report "no stale entries in debian/install" $?

test_service_execstart_paths() {
    result=0
    for svc in "${REPO_DIR}"/systemd/*.service; do
        execstart=$(grep '^ExecStart=' "$svc" | sed 's/^ExecStart=//' | awk '{print $NF}')
        # ExecStart may be like /bin/sh -eu /usr/share/juju-installer/foo
        # We want the script path, which is the last argument
        src_name=$(basename "$execstart")
        if [ ! -f "${REPO_DIR}/share/${src_name}" ]; then
            echo "  ASSERT FAILED: ${src_name} (from $(basename "$svc")) not found in share/"
            result=1
        fi
        if ! grep -q "${src_name}" "${REPO_DIR}/debian/install"; then
            echo "  ASSERT FAILED: ${src_name} not listed in debian/install"
            result=1
        fi
    done
    return $result
}
test_service_execstart_paths; report "service ExecStart paths match source and install" $?

# ============================================================
# Summary
# ============================================================

echo ""
echo "=== Results: ${PASS}/${TOTAL} passed, ${FAIL} failed ==="
[ "$FAIL" -eq 0 ] || exit 1
