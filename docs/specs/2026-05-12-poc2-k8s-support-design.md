# juju-installer PoC2: Canonical K8s Support

**Date:** 2026-05-12
**Status:** Draft
**Builds on:** [PoC1 Design](2026-05-11-juju-installer-design.md)
**Goal:** Extend juju-installer so that `juju deploy postgresql-k8s --trust` on a fresh Ubuntu machine automatically installs Canonical K8s, bootstraps a Juju controller on it, and deploys the charm — zero prior setup.

## Problem

PoC1 solved the VM path: `juju deploy postgresql` on a fresh machine auto-installs LXD + Juju and bootstraps a controller. But Kubernetes charms (e.g., `postgresql-k8s`, `mongodb-k8s`) require a different substrate — Canonical K8s — with its own install, bootstrap, and storage setup sequence.

Today, deploying a Charmed PostgreSQL K8s on a fresh Ubuntu requires:
1. `snap install k8s --classic`
2. `sudo k8s bootstrap`
3. `sudo k8s status --wait-ready`
4. `sudo k8s enable local-storage`
5. `snap install juju`
6. `juju add-k8s ck8s --client`
7. `juju bootstrap ck8s`
8. `juju add-model welcome`
9. `juju deploy postgresql-k8s --trust`

Reference: [Charmed PostgreSQL K8s on Canonical K8s](https://documentation.ubuntu.com/charmed-postgresql-k8s/16/how-to/deploy/canonical-k8s/)

## Solution

Extend the wrapper to detect the target substrate from the charm name and trigger the appropriate service. Add a dedicated K8s service that installs and bootstraps Canonical K8s. Split the existing monolithic service into three substrate-specific services behind separate systemd sockets.

## Changes from PoC1

| Aspect | PoC1 | PoC2 |
|--------|------|------|
| Substrates | LXD only | LXD + Canonical K8s |
| Services | 1 (juju-installer) | 3 (snap, lxd, k8s) |
| Sockets | 1 | 3 |
| Charm type detection | None | Name suffix (`-k8s`) |
| Non-deploy install | Installs juju + LXD | Installs juju snap only |
| Service scripts | 1 | 3 |

## Architecture

### Substrate Detection

The wrapper determines the target substrate from the charm name:

```sh
case "$charm_name" in
    *-k8s) SUBSTRATE=k8s ;;
    *)     SUBSTRATE=lxd ;;
esac
```

Charms ending in `-k8s` (e.g., `postgresql-k8s`, `mongodb-k8s`) target Canonical K8s. All others target LXD. This is a simple heuristic that covers the vast majority of charms in the Canonical ecosystem.

**Charm name extraction:** The wrapper parses `juju deploy <charm> [options]` to extract the charm name. The charm name is the first positional argument after `deploy`. Channel suffixes and flags are ignored — only the base name matters for detection.

**Future improvement:** Query the [Charmhub API](https://api.charmhub.io/v2/charms/info/<name>?fields=default-release.revision.metadata-yaml) to check for the `containers:` key in charm metadata, which is the definitive K8s indicator. This would correctly classify workloadless charms that can run on either substrate. Deferred until Charmhub exposes a first-class charm type field.

### Three-Socket Design

Each substrate gets its own systemd socket/service pair. This keeps service scripts simple, isolated, and easy to extend with substrate-specific workarounds.

```
/sbin/juju (wrapper)
    │
    ├── juju deploy <charm-k8s> (no snap)
    │   └── trigger juju-installer-k8s.socket
    │
    ├── juju deploy <charm> (no snap)
    │   └── trigger juju-installer-lxd.socket
    │
    └── juju <non-deploy> (no snap)
        └── trigger juju-installer-snap.socket
```

**Why separate sockets instead of mode bytes?** Each substrate will accumulate its own workarounds, timeouts, and error handling over time. Separate services keep each path simple and independently testable. Adding a new substrate means adding a new socket/service pair without touching existing ones.

**Why a separate snap-only service?** PoC1 installed LXD alongside Juju even for non-deploy commands (`juju version`). This was wasteful — the user may only want to check Juju's version or run `juju help`. PoC2 defers substrate installation until a `deploy` command reveals which substrate is needed.

### Wrapper Flow

```
juju deploy <charm> (no snap installed)
    ├── check_user (root + cgroup checks)
    ├── check_socket_access
    ├── extract charm name from args
    ├── detect substrate: *-k8s → k8s, else → lxd
    ├── confirm_install
    ├── trigger juju-installer-k8s.socket OR juju-installer-lxd.socket
    ├── wait for /snap/bin/juju to appear
    ├── do_bootstrap_k8s OR do_bootstrap_lxd
    └── exec /snap/bin/juju deploy <charm>

juju <non-deploy> (no snap installed)
    ├── check_user (root + cgroup checks)
    ├── check_socket_access
    ├── confirm_install ("Would you like to install Juju snap now (Y/n)?")
    ├── trigger juju-installer-snap.socket
    ├── wait for /snap/bin/juju to appear
    └── exec /snap/bin/juju <args>

juju <anything> (snap already installed)
    └── exec /snap/bin/juju <args>  (zero-overhead pass-through)
```

The wrapper only has effect on the **first interaction** with juju. Once the snap is installed, every subsequent call is a direct `exec` pass-through — no API calls, no substrate checks, no extra output.

## Component Details

### Wrapper Script (`/sbin/juju`)

The wrapper extends PoC1 with substrate detection and per-substrate bootstrap logic.

**Pre-flight checks (unchanged from PoC1):**
- Root user check — exits if `id -u == 0`
- Cgroup check — exits if running in a system service cgroup
- Socket access check — checks if `/run/juju-installer-snap.socket` is writable (all three sockets have identical `root:lxd 0660` ownership, so checking any one is sufficient to verify group membership)

**Charm name extraction:**

```sh
extract_charm_name() {
    shift
    skip_next=0
    for arg in "$@"; do
        if [ "$skip_next" -eq 1 ]; then
            skip_next=0; continue
        fi
        case "$arg" in
            --*=*) continue ;;
            -*)  skip_next=1; continue ;;
            *)   echo "$arg"; return ;;
        esac
    done
}
```

Called as `charm_name=$(extract_charm_name "$@")` where `$@` includes `deploy` as the first argument (shifted off). This handles `--flag=value` (skip one arg) and `--flag value` / `-f value` (skip two args) to find the first positional argument — the charm name.

**Confirmation prompts (substrate-aware):**
- LXD deploy: `"Would you like to install Juju and LXD snaps now (Y/n)?"`
- K8s deploy: `"Would you like to install Juju and Canonical K8s snaps now (Y/n)?"`
- Non-deploy: `"Would you like to install Juju snap now (Y/n)?"`

**Trigger functions:**

```sh
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
```

### K8s Bootstrap Logic (in the wrapper, as current user)

After the K8s service completes and `/snap/bin/juju` is available, the wrapper performs user-level K8s setup:

1. **Copy kubeconfig** — copies `/run/juju-installer-k8s-kubeconfig` to `~/.kube/config` (chmod 600). The Juju snap can't read arbitrary `/run/` files due to confinement, so the kubeconfig must be in the user's home directory.
2. **Register K8s cloud** — `timeout 60 /snap/bin/juju add-k8s ck8s --client`. Skip if cloud `ck8s` already exists. Detection: `/snap/bin/juju clouds --format json 2>/dev/null | grep -q '"ck8s"'`.
3. **Bootstrap Juju controller** — `timeout 600 /snap/bin/juju bootstrap ck8s`. Skip if controller `ck8s` already exists. Detection: `/snap/bin/juju controllers --format json 2>/dev/null | grep -q '"ck8s"'`.
4. **Create welcome model** — `timeout 60 /snap/bin/juju add-model welcome`. Skip if model `welcome` already exists.

**Progress (K8s path, 9 steps total):**
```
\r[1/9] Preparing Juju environment (this may take a few minutes)...
\r[2/9] Installing Canonical K8s...
\r[3/9] Bootstrapping Canonical K8s...
\r[4/9] Waiting for Canonical K8s to be ready...
\r[5/9] Enabling local storage...
\r[6/9] Exporting kubeconfig...
\r[7/9] Registering Canonical K8s cloud...
\r[8/9] Bootstrapping Juju controller (this may take a few minutes)...
\r[9/9] Creating welcome model...
Hint: run 'juju status' to track deployment progress.
```

Steps 1-6 come from the K8s service (progress to stderr/journal, not displayed in wrapper). The wrapper displays its own steps 7-9 using the `\r` overwriting pattern. The step 1 message is shown by the wrapper while waiting for the service to complete.

**Progress (LXD path, 5 steps total — unchanged from PoC1):**
```
\r[1/5] Preparing Juju environment (this may take a few minutes)...
\r[2/5] Installing LXD...
\r[3/5] Initializing LXD...
\r[4/5] Bootstrapping Juju controller (this may take a few minutes)...
\r[5/5] Creating welcome model...
Hint: run 'juju status' to track deployment progress.
```

### LXD Bootstrap Logic (in the wrapper, as current user)

Unchanged from PoC1:

1. **Bootstrap Juju controller** — `timeout 600 /snap/bin/juju bootstrap lxd lxd`. Skip if controller `lxd` exists.
2. **Create welcome model** — `timeout 60 /snap/bin/juju add-model welcome`. Skip if model exists.

### Service Scripts

#### `juju-installer-snap-service` (juju snap only)

```sh
#!/bin/sh
set -eu
MODE=$(head -c1)

if [ ! -x /snap/bin/juju ]; then
    echo "[1/1] Installing Juju snap..." 1>&2
    snap install juju 1>&2
fi

echo 1
```

Minimal — just installs the juju snap. Used for non-deploy commands.

#### `juju-installer-lxd-service` (juju + LXD)

```sh
#!/bin/sh
set -eu
MODE=$(head -c1)

# Step 1: Install Juju snap
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

# Step 3: Initialize LXD
if ! /snap/bin/lxc storage list --format csv 2>/dev/null | grep -q default; then
    echo "[3/3] Initializing LXD..." 1>&2
    /snap/bin/lxd init --auto 1>&2
fi

echo 1
```

Identical to the current PoC1 `juju-installer-service`, renamed.

#### `juju-installer-k8s-service` (juju + Canonical K8s)

```sh
#!/bin/sh
set -eu
MODE=$(head -c1)

# Step 1: Install Juju snap
if [ ! -x /snap/bin/juju ]; then
    echo "[1/6] Installing Juju snap..." 1>&2
    snap install juju 1>&2
fi

# Step 2: Install Canonical K8s snap
if [ ! -x /snap/bin/k8s ]; then
    echo "[2/6] Installing Canonical K8s..." 1>&2
    snap install k8s --classic 1>&2
fi

# Step 3: Bootstrap Canonical K8s
# Detection: k8s status exits non-zero or reports not-ready when unbootstrapped
if ! /snap/bin/k8s status >/dev/null 2>&1; then
    echo "[3/6] Bootstrapping Canonical K8s..." 1>&2
    /snap/bin/k8s bootstrap 1>&2
fi

# Step 4: Wait for K8s to be ready (retry up to 5 minutes)
echo "[4/6] Waiting for Canonical K8s to be ready..." 1>&2
i=0
while [ "$i" -lt 60 ]; do
    if /snap/bin/k8s status --wait-ready --timeout 5 >/dev/null 2>&1; then
        break
    fi
    sleep 5
    i=$((i + 1))
done
if ! /snap/bin/k8s status 2>/dev/null | grep -q "cluster status:.*ready"; then
    echo "ERROR: Canonical K8s did not become ready." 1>&2
    exit 1
fi

# Step 5: Enable local storage
if ! /snap/bin/k8s status 2>/dev/null | grep -q "local-storage.*enabled"; then
    echo "[5/6] Enabling local storage..." 1>&2
    /snap/bin/k8s enable local-storage 1>&2
fi

# Step 6: Export kubeconfig for the calling user
echo "[6/6] Exporting kubeconfig..." 1>&2
/snap/bin/k8s config > /run/juju-installer-k8s-kubeconfig
chmod 0640 /run/juju-installer-k8s-kubeconfig
chgrp lxd /run/juju-installer-k8s-kubeconfig

echo 1
```

All progress goes to stderr (journal). Only the completion byte `1` goes to stdout (socket).

### Systemd Units

**`juju-installer-snap.socket`:**
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

**`juju-installer-snap@.service`:**
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

**`juju-installer-lxd.socket`:**
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

**`juju-installer-lxd@.service`:**
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

**`juju-installer-k8s.socket`:**
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

**`juju-installer-k8s@.service`:**
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
PrivateTmp=yes
```

K8s service gets `TimeoutStartSec=900` (15 minutes) because `k8s bootstrap` + `k8s status --wait-ready` can take longer than LXD setup. No `ProtectHome=yes` — the k8s snap needs write access to `/root/snap/k8s/` during bootstrap.

### Socket Ownership

Same as PoC1: all sockets use `root:lxd`, mode `0660`. The `lxd` group is guaranteed to exist because the package depends on `lxd-installer`.

Future (PoC3): create a dedicated `juju` system group.

## Package Contents

```
/sbin/juju                                                  # wrapper script
/usr/lib/systemd/system/juju-installer-snap.socket          # juju snap only
/usr/lib/systemd/system/juju-installer-snap@.service
/usr/lib/systemd/system/juju-installer-lxd.socket           # juju + LXD
/usr/lib/systemd/system/juju-installer-lxd@.service
/usr/lib/systemd/system/juju-installer-k8s.socket           # juju + K8s
/usr/lib/systemd/system/juju-installer-k8s@.service
/usr/share/juju-installer/juju-installer-snap-service       # snap-only script
/usr/share/juju-installer/juju-installer-lxd-service        # LXD script
/usr/share/juju-installer/juju-installer-k8s-service        # K8s script
```

### Package Metadata

```
Package: juju-installer
Architecture: all
Depends: lxd-installer, python3, ${misc:Depends}
Provides: juju
Description: Wrapper to install and bootstrap Juju on demand
 Provides a /sbin/juju wrapper that automatically installs the Juju snap
 and bootstraps either an LXD or Canonical K8s environment when the user
 first runs a juju deploy command.
```

No new dependencies. The `k8s` snap is installed at runtime by the K8s service.

### Debian Packaging

**`debian/postinst`:**
- Enable and start all three sockets: `juju-installer-snap.socket`, `juju-installer-lxd.socket`, `juju-installer-k8s.socket`

**`debian/prerm`:**
- Stop and disable all three sockets

**`debian/postrm`:**
- On purge: remove `/run/juju-installer-snap.socket`, `/run/juju-installer-lxd.socket`, `/run/juju-installer-k8s.socket` if present

**`debian/install`:**
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

## Resilience and Recovery

Same principles as PoC1 — every step is idempotent with precondition checks, no intermediate state files.

| Failure point | What happens on re-run |
|---|---|
| Network drops during `snap install k8s` | Service retries snap install |
| `k8s bootstrap` interrupted | Service detects K8s not ready, re-runs bootstrap |
| `k8s enable local-storage` fails | Service retries |
| `juju add-k8s ck8s` fails | Wrapper retries (checks if cloud exists first) |
| `juju bootstrap ck8s` interrupted | Wrapper detects no controller, re-runs bootstrap |
| `juju add-model welcome` fails | Wrapper retries |
| Timeout in wrapper wait loop | User re-runs, service may still be finishing — wrapper detects snap and skips |

Note: once the juju snap is installed, re-running `juju deploy <charm-k8s>` will pass through directly to `/snap/bin/juju` — the wrapper won't attempt K8s bootstrap again. The wrapper only intervenes when no snap exists. This is by design: after first setup, the user is no longer a newbie and should manage their environment manually.

## Security Considerations

All PoC1 security properties are preserved:

1. **No user data crosses the privilege boundary.** Each socket receives exactly one byte. Service scripts are hardcoded.
2. **Socket access control.** All three sockets: `root:lxd`, mode `0660`.
3. **Idempotent operations.** Safe to re-trigger any service.
4. **No ARGV pass-through.** User's juju arguments never touch the sockets.
5. **Clean privilege split.** Root operations (snap install, k8s bootstrap, lxd init) in services. User operations (juju bootstrap, add-model) in wrapper.
6. **Root user check.** Wrapper rejects `id -u == 0`.
7. **Cgroup check.** Wrapper rejects non-login sessions.

The K8s service runs `k8s bootstrap` as root, which is correct — Canonical K8s requires root for cluster initialization. The `--classic` confinement of the k8s snap is necessary for K8s to manage system resources (networking, storage, containers).

## Timeouts

| Operation | Where it runs | Timeout | Mechanism |
|-----------|--------------|---------|-----------|
| Snap service total (juju only) | Service (root) | 300s | `TimeoutStartSec` |
| LXD service total | Service (root) | 600s | `TimeoutStartSec` |
| K8s service total | Service (root) | 900s | `TimeoutStartSec` |
| Wrapper wait for snap | Wrapper (user) | 90s | poll loop |
| `juju add-k8s ck8s` | Wrapper (user) | 60s | `timeout 60` |
| `juju bootstrap ck8s` | Wrapper (user) | 600s | `timeout 600` |
| `juju bootstrap lxd lxd` | Wrapper (user) | 600s | `timeout 600` |
| `juju add-model welcome` | Wrapper (user) | 60s | `timeout 60` |

## Scope and Limitations

- **PoC2 scope:** Add Canonical K8s substrate support alongside existing LXD.
- **Name-based detection only.** Charm type is determined by `-k8s` suffix. Workloadless charms always go to LXD. Charmhub API detection deferred.
- **First-time only.** Wrapper only bootstraps on first `deploy` (snap not installed). Subsequent deploys pass through.
- **Single controller per substrate.** Wrapper doesn't manage multiple controllers. One `lxd` controller for VM, one `ck8s` controller for K8s.
- **Default snap channels only.** `snap install juju` (default), `snap install k8s --classic` (default/stable).
- **Ubuntu 24.04+ target.**

## Future Work (Out of Scope for PoC2)

- **Charmhub API detection:** Query charm metadata for `containers:` key instead of name suffix
- **Dedicated `juju` system group** instead of reusing `lxd` group
- **Dual-controller coexistence:** Bootstrap both LXD and K8s on the same machine
- **Re-bootstrap after snap installed:** If user ran `juju version` (snap installed), then `juju deploy postgresql-k8s`, detect missing K8s controller and bootstrap
- **Channel selection:** Config file for snap channels
- **kubectl integration:** Install kubectl for K8s troubleshooting

## Testing Strategy

### Unit Tests (extend existing test_wrapper.sh)

- **Substrate detection:** `postgresql` → lxd, `postgresql-k8s` → k8s, `data-integrator` → lxd
- **K8s bootstrap path:** deploy `-k8s` charm triggers K8s service and K8s bootstrap
- **LXD bootstrap path:** deploy non-k8s charm triggers LXD service and LXD bootstrap
- **Non-deploy path:** `juju version` triggers snap-only service, no substrate setup
- **Charm name extraction:** handles flags, channels, and positional args correctly
- **All existing PoC1 tests remain passing**

### Integration Tests (in fresh LXD VM)

1. Fresh Ubuntu 24.04 → `juju deploy postgresql` → verify LXD + Juju bootstrapped, PostgreSQL deploying
2. Fresh Ubuntu 24.04 → `juju deploy postgresql-k8s --trust` → verify K8s + Juju bootstrapped, PostgreSQL K8s deploying
3. Fresh Ubuntu 24.04 → `juju version` → verify only juju snap installed (no LXD, no K8s)
4. Fresh Ubuntu 26.04 → repeat tests 1-3
5. Idempotency: run K8s service twice, verify no errors or duplicate resources
6. Root check: `juju deploy postgresql-k8s` as root → error
7. All three sockets enabled after package install
