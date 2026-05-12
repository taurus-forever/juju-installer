# PoC2: Canonical K8s Support Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extend juju-installer to auto-bootstrap Canonical K8s when user runs `juju deploy <charm>-k8s`, splitting the monolithic service into three substrate-specific socket/service pairs.

**Architecture:** The wrapper detects substrate from charm name suffix (`-k8s` -> K8s, else -> LXD). Three separate systemd socket/service pairs handle root-level setup: snap-only (for non-deploy), LXD (juju + LXD + init), and K8s (juju + k8s + bootstrap + local-storage). User-level bootstrap (juju controllers/models) stays in the wrapper.

**Tech Stack:** POSIX shell, systemd socket activation, python3 (socket only), dpkg/debhelper

**Design spec:** `docs/specs/2026-05-12-poc2-k8s-support-design.md`

---

## File Structure

### Files to create
- `share/juju-installer-snap-service` -- snap-only install script (replaces old service for non-deploy)
- `share/juju-installer-lxd-service` -- LXD install script (rename of existing `juju-installer-service`)
- `share/juju-installer-k8s-service` -- K8s install script (new)
- `systemd/juju-installer-snap.socket` -- socket for snap-only
- `systemd/juju-installer-snap@.service` -- service for snap-only
- `systemd/juju-installer-lxd.socket` -- socket for LXD
- `systemd/juju-installer-lxd@.service` -- service for LXD
- `systemd/juju-installer-k8s.socket` -- socket for K8s
- `systemd/juju-installer-k8s@.service` -- service for K8s

### Files to modify
- `sbin/juju` -- rewrite main logic with substrate detection, per-substrate triggers and bootstrap
- `debian/install` -- update file mappings for new services/sockets
- `debian/control` -- update description
- `debian/changelog` -- bump version
- `tests/test_wrapper.sh` -- rewrite tests for new wrapper logic

### Files to delete
- `share/juju-installer-service` -- replaced by `juju-installer-lxd-service`
- `systemd/juju-installer.socket` -- replaced by three substrate sockets
- `systemd/juju-installer@.service` -- replaced by three substrate services

---

### Task 1: Create snap-only service script and systemd units

**Files:**
- Create: `share/juju-installer-snap-service`
- Create: `systemd/juju-installer-snap.socket`
- Create: `systemd/juju-installer-snap@.service`

- [ ] **Step 1: Create `share/juju-installer-snap-service`**

```sh
#!/bin/sh
set -eu

# Read mode byte from wrapper
# shellcheck disable=SC2034
MODE=$(head -c1)

# Install Juju snap if not present
if [ ! -x /snap/bin/juju ]; then
    echo "[1/1] Installing Juju snap..." 1>&2
    snap install juju 1>&2
fi

# Signal completion
echo 1
```

- [ ] **Step 2: Create `systemd/juju-installer-snap.socket`**

```ini
[Unit]
Description=Helper to install Juju snap on demand

[Socket]
ListenStream=/run/juju-installer-snap.socket
SocketUser=root
SocketGroup=lxd
SocketMode=0660
Accept=true
MaxConnections=1

[Install]
WantedBy=multi-user.target
```

- [ ] **Step 3: Create `systemd/juju-installer-snap@.service`**

```ini
[Unit]
Description=Helper to install Juju snap on demand

[Service]
ExecStart=/bin/sh -eu /usr/share/juju-installer/juju-installer-snap-service
StandardInput=socket
StandardOutput=socket
StandardError=journal
Restart=no
TimeoutStartSec=300
ProtectHome=yes
PrivateTmp=yes
```

- [ ] **Step 4: Commit**

```bash
git add share/juju-installer-snap-service systemd/juju-installer-snap.socket systemd/juju-installer-snap@.service
git commit -m "feat: add snap-only service for non-deploy commands"
```

---

### Task 2: Rename existing service to LXD-specific service

**Files:**
- Delete: `share/juju-installer-service`
- Create: `share/juju-installer-lxd-service`
- Delete: `systemd/juju-installer.socket`
- Delete: `systemd/juju-installer@.service`
- Create: `systemd/juju-installer-lxd.socket`
- Create: `systemd/juju-installer-lxd@.service`

- [ ] **Step 1: Create `share/juju-installer-lxd-service`**

This is the existing `share/juju-installer-service` content, unchanged:

```sh
#!/bin/sh
set -eu

# Read mode byte from wrapper
# shellcheck disable=SC2034
MODE=$(head -c1)

# Step 1: Install Juju snap if not present
if [ ! -x /snap/bin/juju ]; then
    echo "[1/3] Installing Juju snap..." 1>&2
    snap install juju 1>&2
fi

# Step 2: Ensure LXD snap is available
if [ ! -x /snap/bin/lxd ]; then
    echo "[2/3] Installing LXD..." 1>&2
    python3 -c 'import socket; s=socket.socket(socket.AF_UNIX); s.connect("/run/lxd-installer.socket"); s.send(b"x"); s.recv(1)' 1>&2
    i=0
    while [ "$i" -lt 90 ]; do
        sleep 1
        [ -x /snap/bin/lxd ] && break
        i=$((i + 1))
    done
    if [ ! -x /snap/bin/lxd ]; then
        echo "ERROR: LXD snap installation timed out." 1>&2
        exit 1
    fi
fi

# Step 3: Initialize LXD if needed
if ! /snap/bin/lxc storage list --format csv 2>/dev/null | grep -q default; then
    echo "[3/3] Initializing LXD..." 1>&2
    /snap/bin/lxd init --auto 1>&2
fi

# Signal completion
echo 1
```

- [ ] **Step 2: Create `systemd/juju-installer-lxd.socket`**

```ini
[Unit]
Description=Helper to install Juju and bootstrap LXD on demand

[Socket]
ListenStream=/run/juju-installer-lxd.socket
SocketUser=root
SocketGroup=lxd
SocketMode=0660
Accept=true
MaxConnections=1

[Install]
WantedBy=multi-user.target
```

- [ ] **Step 3: Create `systemd/juju-installer-lxd@.service`**

```ini
[Unit]
Description=Helper to install Juju and bootstrap LXD on demand

[Service]
ExecStart=/bin/sh -eu /usr/share/juju-installer/juju-installer-lxd-service
StandardInput=socket
StandardOutput=socket
StandardError=journal
Restart=no
TimeoutStartSec=600
ProtectHome=yes
PrivateTmp=yes
```

- [ ] **Step 4: Delete old files**

```bash
git rm share/juju-installer-service systemd/juju-installer.socket systemd/juju-installer@.service
```

- [ ] **Step 5: Commit**

```bash
git add share/juju-installer-lxd-service systemd/juju-installer-lxd.socket systemd/juju-installer-lxd@.service
git commit -m "refactor: rename service to juju-installer-lxd, delete old monolithic service"
```

---

### Task 3: Create K8s service script and systemd units

**Files:**
- Create: `share/juju-installer-k8s-service`
- Create: `systemd/juju-installer-k8s.socket`
- Create: `systemd/juju-installer-k8s@.service`

- [ ] **Step 1: Create `share/juju-installer-k8s-service`**

```sh
#!/bin/sh
set -eu

# Read mode byte from wrapper
# shellcheck disable=SC2034
MODE=$(head -c1)

# Step 1: Install Juju snap if not present
if [ ! -x /snap/bin/juju ]; then
    echo "[1/5] Installing Juju snap..." 1>&2
    snap install juju 1>&2
fi

# Step 2: Install Canonical K8s snap if not present
if [ ! -x /snap/bin/k8s ]; then
    echo "[2/5] Installing Canonical K8s..." 1>&2
    snap install k8s --classic 1>&2
fi

# Step 3: Bootstrap Canonical K8s if not already bootstrapped
if ! /snap/bin/k8s status >/dev/null 2>&1; then
    echo "[3/5] Bootstrapping Canonical K8s..." 1>&2
    /snap/bin/k8s bootstrap 1>&2
fi

# Step 4: Wait for K8s to be ready
echo "[4/5] Waiting for Canonical K8s to be ready..." 1>&2
/snap/bin/k8s status --wait-ready 1>&2

# Step 5: Enable local storage if not already enabled
if ! /snap/bin/k8s status 2>/dev/null | grep -q "local-storage.*enabled"; then
    echo "[5/5] Enabling local storage..." 1>&2
    /snap/bin/k8s enable local-storage 1>&2
fi

# Signal completion
echo 1
```

- [ ] **Step 2: Create `systemd/juju-installer-k8s.socket`**

```ini
[Unit]
Description=Helper to install Juju and bootstrap Canonical K8s on demand

[Socket]
ListenStream=/run/juju-installer-k8s.socket
SocketUser=root
SocketGroup=lxd
SocketMode=0660
Accept=true
MaxConnections=1

[Install]
WantedBy=multi-user.target
```

- [ ] **Step 3: Create `systemd/juju-installer-k8s@.service`**

```ini
[Unit]
Description=Helper to install Juju and bootstrap Canonical K8s on demand

[Service]
ExecStart=/bin/sh -eu /usr/share/juju-installer/juju-installer-k8s-service
StandardInput=socket
StandardOutput=socket
StandardError=journal
Restart=no
TimeoutStartSec=900
ProtectHome=yes
PrivateTmp=yes
```

- [ ] **Step 4: Commit**

```bash
git add share/juju-installer-k8s-service systemd/juju-installer-k8s.socket systemd/juju-installer-k8s@.service
git commit -m "feat: add K8s service to install Canonical K8s and enable local storage"
```

---

### Task 4: Rewrite wrapper script with substrate detection

This is the largest task -- the wrapper gets substrate detection, per-substrate triggers, and per-substrate bootstrap.

**Files:**
- Modify: `sbin/juju`

- [ ] **Step 1: Write the new wrapper script**

Replace the entire contents of `sbin/juju` with:

```sh
#!/bin/sh
SNAP_BIN="/snap/bin/juju"

# --- Helper functions ---

show_progress() {
    printf "\r%-70s" "$1" >&2
}

clear_progress() {
    printf "\r%-70s\r" "" >&2
}

confirm_install() {
    printf "%s " "$1" >&2
    read -r answer < /dev/tty || answer="y"
    case "$answer" in
        [nN]*) echo "Aborted." >&2; exit 0 ;;
    esac
}

check_user() {
    if [ "$(id -u)" -eq 0 ]; then
        echo "ERROR: Do not run 'juju deploy' as root." >&2
        echo "Juju stores configuration in ~/.local/share/juju which is" >&2
        echo "not accessible to snaps under /root." >&2
        echo "Run as a regular user instead." >&2
        exit 1
    fi
    if grep -q '/system\.slice/.*\.service' /proc/self/cgroup 2>/dev/null; then
        echo "WARNING: This shell is not running in a regular login session." >&2
        echo "Do not run the first 'juju deploy' under su or sudo." >&2
        echo "Use SSH or log in directly as your user instead." >&2
        exit 1
    fi
}

check_socket_access() {
    if [ ! -w "/run/juju-installer-snap.socket" ]; then
        echo "Unable to trigger the installation of Juju." >&2
        echo "Please make sure you're a member of the 'lxd' system group." >&2
        echo "Run: sudo adduser $(id -un) lxd && newgrp lxd" >&2
        exit 1
    fi
}

# --- Substrate detection ---

extract_charm_name() {
    # Skip "deploy", then return first non-flag arg
    shift
    for arg in "$@"; do
        case "$arg" in
            -*) continue ;;
            *)  echo "$arg"; return ;;
        esac
    done
}

detect_substrate() {
    case "$1" in
        *-k8s) echo "k8s" ;;
        *)     echo "lxd" ;;
    esac
}

is_deploy_command() {
    [ "${1:-}" = "deploy" ]
}

# --- Service triggers ---

trigger_snap_service() {
    python3 -c '
import socket; s=socket.socket(socket.AF_UNIX)
s.connect("/run/juju-installer-snap.socket"); s.send(b"i"); s.recv(1)
' >/dev/null
}

trigger_lxd_service() {
    python3 -c '
import socket; s=socket.socket(socket.AF_UNIX)
s.connect("/run/juju-installer-lxd.socket"); s.send(b"i"); s.recv(1)
' >/dev/null
}

trigger_k8s_service() {
    python3 -c '
import socket; s=socket.socket(socket.AF_UNIX)
s.connect("/run/juju-installer-k8s.socket"); s.send(b"i"); s.recv(1)
' >/dev/null
}

wait_for_snap() {
    i=0
    while [ "$i" -lt 90 ]; do
        sleep 1
        [ -x "${SNAP_BIN}" ] && return 0
        i=$((i + 1))
    done
    clear_progress
    echo "ERROR: Juju snap installation timed out." >&2
    exit 1
}

# --- Bootstrap functions ---

has_lxd_controller() {
    "${SNAP_BIN}" controllers --format json 2>/dev/null | grep -q '"lxd"'
}

has_k8s_cloud() {
    "${SNAP_BIN}" clouds --format json 2>/dev/null | grep -q '"ck8s"'
}

has_k8s_controller() {
    "${SNAP_BIN}" controllers --format json 2>/dev/null | grep -q '"ck8s"'
}

has_model() {
    "${SNAP_BIN}" models --format json 2>/dev/null | grep -q '"welcome"'
}

do_bootstrap_lxd() {
    if ! has_lxd_controller; then
        show_progress "[4/5] Bootstrapping Juju controller (this may take a few minutes)..."
        if ! timeout 600 "${SNAP_BIN}" bootstrap lxd lxd >/dev/null 2>&1; then
            clear_progress
            echo "ERROR: Juju bootstrap failed or timed out. Re-run the command to retry." >&2
            exit 1
        fi
    fi

    if ! has_model; then
        show_progress "[5/5] Creating welcome model..."
        if ! timeout 60 "${SNAP_BIN}" add-model welcome >/dev/null 2>&1; then
            clear_progress
            echo "ERROR: Failed to create welcome model. Re-run the command to retry." >&2
            exit 1
        fi
    fi

    clear_progress
    BOOTSTRAPPED=1
}

do_bootstrap_k8s() {
    if ! has_k8s_cloud; then
        show_progress "[6/8] Registering Canonical K8s cloud..."
        if ! timeout 60 "${SNAP_BIN}" add-k8s ck8s --client >/dev/null 2>&1; then
            clear_progress
            echo "ERROR: Failed to register K8s cloud. Re-run the command to retry." >&2
            exit 1
        fi
    fi

    if ! has_k8s_controller; then
        show_progress "[7/8] Bootstrapping Juju controller (this may take a few minutes)..."
        if ! timeout 600 "${SNAP_BIN}" bootstrap ck8s >/dev/null 2>&1; then
            clear_progress
            echo "ERROR: Juju bootstrap on K8s failed or timed out. Re-run the command to retry." >&2
            exit 1
        fi
    fi

    if ! has_model; then
        show_progress "[8/8] Creating welcome model..."
        if ! timeout 60 "${SNAP_BIN}" add-model welcome >/dev/null 2>&1; then
            clear_progress
            echo "ERROR: Failed to create welcome model. Re-run the command to retry." >&2
            exit 1
        fi
    fi

    clear_progress
    BOOTSTRAPPED=1
}

BOOTSTRAPPED=0

# --- Main logic ---

if [ ! -x "${SNAP_BIN}" ]; then
    check_user
    check_socket_access

    if is_deploy_command "$@"; then
        charm_name=$(extract_charm_name "$@")
        substrate=$(detect_substrate "${charm_name:-}")

        if [ "$substrate" = "k8s" ]; then
            confirm_install "Would you like to install Juju and Canonical K8s snaps now (Y/n)?"
            show_progress "[1/8] Preparing Juju environment (this may take a few minutes)..."
            trigger_k8s_service
            wait_for_snap
            do_bootstrap_k8s
        else
            confirm_install "Would you like to install Juju and LXD snaps now (Y/n)?"
            show_progress "[1/5] Preparing Juju environment (this may take a few minutes)..."
            trigger_lxd_service
            wait_for_snap
            do_bootstrap_lxd
        fi
    else
        confirm_install "Would you like to install Juju snap now (Y/n)?"
        trigger_snap_service
        wait_for_snap
    fi
fi

if [ "$BOOTSTRAPPED" -eq 1 ]; then
    "${SNAP_BIN}" "$@"
    rc=$?
    [ "$rc" -eq 0 ] && echo "Hint: run 'juju status' to track deployment progress." >&2
    exit "$rc"
fi
exec "${SNAP_BIN}" "$@"
```

- [ ] **Step 2: Verify the script is syntactically valid**

Run: `sh -n sbin/juju`
Expected: no output (no syntax errors)

- [ ] **Step 3: Commit**

```bash
git add sbin/juju
git commit -m "feat: rewrite wrapper with substrate detection and per-substrate bootstrap"
```

---

### Task 5: Update tests for new wrapper

The test suite needs significant changes because:
- Socket path changed from `/run/juju-installer.socket` to `/run/juju-installer-snap.socket` (and `-lxd`, `-k8s`)
- `trigger_service` is now three functions: `trigger_snap_service`, `trigger_lxd_service`, `trigger_k8s_service`
- `do_bootstrap` is now `do_bootstrap_lxd` and `do_bootstrap_k8s`
- `has_controller` is now `has_lxd_controller` and `has_k8s_controller`
- New functions: `extract_charm_name`, `detect_substrate`, `has_k8s_cloud`
- Prompt text changed for deploy commands (substrate-aware)

**Files:**
- Modify: `tests/test_wrapper.sh`

- [ ] **Step 1: Rewrite `tests/test_wrapper.sh`**

Replace the entire file with the following. Key changes from PoC1 tests:
- `setup()` creates three fake sockets (snap, lxd, k8s) instead of one
- `patch_wrapper()` patches all three socket paths and stubs all three trigger functions
- New substrate detection tests
- New charm name extraction tests
- K8s-specific prompt and bootstrap tests
- Updated LXD prompt tests ("Juju and LXD snaps" instead of "Juju snaps")

```sh
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
    # Build a patched copy of the wrapper for testing.
    # Accepts optional extra sed expressions as arguments.
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
    sed -i "/^SNAP_BIN=/a\\
trigger_snap_service() { mkdir -p \"\$(dirname \"${FAKE_SNAP_BIN}\")\"; printf '#!/bin/sh\\\\necho \"mock-juju \$@\"\\\\n' > \"${FAKE_SNAP_BIN}\"; chmod +x \"${FAKE_SNAP_BIN}\"; }\\
trigger_lxd_service() { mkdir -p \"\$(dirname \"${FAKE_SNAP_BIN}\")\"; printf '#!/bin/sh\\\\necho \"mock-juju \$@\"\\\\n' > \"${FAKE_SNAP_BIN}\"; chmod +x \"${FAKE_SNAP_BIN}\"; }\\
trigger_k8s_service() { mkdir -p \"\$(dirname \"${FAKE_SNAP_BIN}\")\"; printf '#!/bin/sh\\\\necho \"mock-juju \$@\"\\\\n' > \"${FAKE_SNAP_BIN}\"; chmod +x \"${FAKE_SNAP_BIN}\"; }" "${PATCHED}"

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
    # Run the already-patched wrapper with given args
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
    # Override auto-accept to auto-reject to capture prompt text
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
    # Don't create sockets
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
    # Override auto-accept to auto-reject
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
    assert_stderr_contains "\[1/8\]" || result=1
    teardown
    return $result
}
test_k8s_progress_step_count; report "K8s path shows [1/8]" $?

# ============================================================
# Summary
# ============================================================

echo ""
echo "=== Results: ${PASS}/${TOTAL} passed, ${FAIL} failed ==="
[ "$FAIL" -eq 0 ] || exit 1
```

- [ ] **Step 2: Run the tests**

Run: `sh tests/test_wrapper.sh`
Expected: all tests pass (22/22)

- [ ] **Step 3: Commit**

```bash
git add tests/test_wrapper.sh
git commit -m "test: rewrite tests for PoC2 substrate detection and three-socket design"
```

---

### Task 6: Update debian packaging

**Files:**
- Modify: `debian/install`
- Modify: `debian/control`
- Modify: `debian/changelog`

- [ ] **Step 1: Replace `debian/install` contents**

```
sbin/juju                                     sbin/
share/juju-installer-snap-service             usr/share/juju-installer/
share/juju-installer-lxd-service              usr/share/juju-installer/
share/juju-installer-k8s-service              usr/share/juju-installer/
systemd/juju-installer-snap.socket            usr/lib/systemd/system/
systemd/juju-installer-snap@.service          usr/lib/systemd/system/
systemd/juju-installer-lxd.socket             usr/lib/systemd/system/
systemd/juju-installer-lxd@.service           usr/lib/systemd/system/
systemd/juju-installer-k8s.socket             usr/lib/systemd/system/
systemd/juju-installer-k8s@.service           usr/lib/systemd/system/
```

- [ ] **Step 2: Update `debian/control` description**

Replace the `Description` field in the `Package` stanza with:

```
Description: Wrapper to install and bootstrap Juju on demand
 Provides a /sbin/juju wrapper that automatically installs the Juju snap
 and bootstraps either an LXD or Canonical K8s environment when the user
 first runs a juju deploy command. This enables a one-command experience
 for trying Juju charms on a fresh Ubuntu system.
 .
 VM charms (e.g., postgresql) are deployed on LXD. K8s charms (e.g.,
 postgresql-k8s) are deployed on Canonical K8s. The substrate is detected
 automatically from the charm name.
```

- [ ] **Step 3: Add new changelog entry at the top of `debian/changelog`**

```
juju-installer (0.1.0) noble; urgency=medium

  * PoC2: Add Canonical K8s substrate support.
  * Split monolithic service into three: snap-only, LXD, K8s.
  * Add substrate detection from charm name suffix (-k8s).
  * Non-deploy commands now install juju snap only (no LXD).
  * Rewrite tests for new three-socket architecture.

 -- Ubuntu Developers <ubuntu-devel-discuss@lists.ubuntu.com>  Mon, 12 May 2026 12:00:00 +0000
```

- [ ] **Step 4: Verify package builds**

Run: `dpkg-buildpackage -us -uc -b`
Expected: build succeeds, produces `../juju-installer_0.1.0_all.deb`

- [ ] **Step 5: Verify package contents**

Run: `dpkg-deb -c ../juju-installer_0.1.0_all.deb | grep -E '(sbin|share|systemd)' | sort`
Expected output should list all 10 files:
```
./sbin/juju
./usr/lib/systemd/system/juju-installer-k8s.socket
./usr/lib/systemd/system/juju-installer-k8s@.service
./usr/lib/systemd/system/juju-installer-lxd.socket
./usr/lib/systemd/system/juju-installer-lxd@.service
./usr/lib/systemd/system/juju-installer-snap.socket
./usr/lib/systemd/system/juju-installer-snap@.service
./usr/share/juju-installer/juju-installer-k8s-service
./usr/share/juju-installer/juju-installer-lxd-service
./usr/share/juju-installer/juju-installer-snap-service
```

- [ ] **Step 6: Commit**

```bash
git add debian/install debian/control debian/changelog
git commit -m "chore: update debian packaging for PoC2 three-socket architecture"
```
