# juju-installer: One-Command Juju Experience

**Date:** 2026-05-11
**Status:** Draft
**Goal:** Enable `juju deploy postgresql` on a fresh Ubuntu 24.04 with zero prior setup.

## Problem

Today, deploying a Charmed PostgreSQL on a fresh Ubuntu requires:
1. Installing the LXD snap
2. Running `lxd init --auto`
3. Installing the Juju snap
4. Running `juju bootstrap lxd lxd`
5. Running `juju add-model welcome`
6. Running `juju deploy postgresql`

This is documented in the [charm-dev blueprint](https://github.com/canonical/multipass-blueprints/blob/main/v1/charm-dev.yaml) and is a significant barrier for newcomers who just want to try Juju/Charms.

## Solution

A lightweight Debian package (`juju-installer`) that provides a `/sbin/juju` wrapper. When the user runs any `juju` command, the wrapper installs the Juju snap on demand. When the user runs `juju deploy ...`, the wrapper also bootstraps the full LXD + Juju controller + model environment automatically.

This mirrors the existing `lxd-installer` package pattern on Ubuntu, which auto-installs the LXD snap when a user first runs `lxd` or `lxc`.

## Reference Implementation: lxd-installer

The `lxd-installer` package (already shipped in Ubuntu 24.04) consists of:
- `/sbin/lxc` and `/sbin/lxd` — wrapper scripts that check for `/snap/bin/lxc|lxd`
- `lxd-installer.socket` — systemd socket at `/run/lxd-installer.socket` (root:lxd, 0660)
- `lxd-installer@.service` — socket-activated service that runs `snap install lxd`
- `/usr/share/lxd-installer/lxd-installer-service` — the install script

The wrapper connects to the Unix socket, sends one byte, waits for a response. The socket-activated service runs as root and installs the snap. No sudo required from the user. The entire package is ~4KB.

## Architecture

### Single-Socket Design with Split Responsibilities

**Root operations (service via socket):** `snap install juju`, trigger `lxd-installer`, `lxd init --auto` — system-level operations that require root.

**User operations (wrapper, no root):** `juju bootstrap lxd lxd`, `juju add-model welcome` — user-level operations that talk to LXD via the unix socket (accessible to `lxd` group members). Config is written to `~/.local/share/juju` naturally since the wrapper runs as the calling user.

The wrapper sends a single byte over the socket to indicate mode:
- `i` — install Juju snap only (+ ensure LXD is ready)
- `b` — same as `i` (service-side is identical; the bootstrap happens in the wrapper after the service completes)

No user-controlled data crosses the privilege boundary. The service script is entirely hardcoded. The socket is a trigger, not a command channel.

### Resilience and Recovery

The wrapper and service are designed to **resume from any point of failure**. If the user's network drops mid-download, the machine reboots during bootstrap, or any step times out, re-running the same `juju` command picks up where it left off.

This is achieved through two principles:

1. **Every step is idempotent with precondition checks.** Each step checks whether its goal is already achieved before acting (e.g., "is snap installed?", "does controller exist?"). A step that previously completed is skipped. A step that previously failed is retried.
2. **No intermediate state files.** The wrapper does not track "which step we're on" — it re-evaluates the full chain every time. This means there is no stale state to clean up after a crash.

Failure scenarios and recovery:

| Failure point | What happens on re-run |
|---|---|
| Network drops during `snap install juju` | Service retries snap install from scratch |
| `lxd init --auto` fails | Service retries LXD init |
| `juju bootstrap` interrupted | Wrapper detects no controller, re-runs bootstrap (Juju cleans up partial state) |
| `juju add-model` fails after bootstrap | Wrapper detects controller exists, skips bootstrap, retries add-model |
| Timeout in wrapper wait loop | User re-runs command, service may still be finishing — wrapper detects snap/controller and skips completed steps |
| Machine reboots mid-process | Socket is re-enabled on boot (`WantedBy=multi-user.target`), re-run resumes |

### Package Contents

```
/sbin/juju                                        # wrapper script
/usr/lib/systemd/system/juju-installer.socket      # systemd socket unit
/usr/lib/systemd/system/juju-installer@.service     # systemd service unit
/usr/share/juju-installer/juju-installer-service    # install/bootstrap logic
```

Plus standard Debian packaging files (`debian/control`, `debian/rules`, `debian/install`, `debian/postinst`, `debian/changelog`, etc.).

### Package Metadata

- **Package:** `juju-installer`
- **Architecture:** `all`
- **Depends:** `lxd-installer` (ensures LXD wrapper is available on the system)
- **Provides:** `juju` (so `apt install juju` resolves to `juju-installer`)
- **Conflicts:** (none for MVP; a future transitional `juju` deb would conflict)
- **Priority:** optional
- **Section:** admin

**PATH precedence:** The wrapper at `/sbin/juju` must appear before `/snap/bin/juju` in `$PATH`. This is the default on Ubuntu (`/sbin` precedes `/snap/bin`). Once the snap is installed, the wrapper detects it and does a zero-overhead `exec` pass-through.

### Socket Ownership

For MVP (PoC1): reuse the `lxd` system group. Socket is `root:lxd`, mode `0660`.
Future (PoC2): create a dedicated `juju` system group (if necessary).

## Component Details

### Wrapper Script (`/sbin/juju`)

The wrapper is the user-facing entry point. Before any installation or bootstrap operation, the wrapper performs two pre-flight checks:

**Cgroup check (snap confinement guard):** Snapd enforces that snap commands run within a recognized cgroup context (user login session, snap service, etc.). When a user enters a system via non-login methods — `su`, `sudo -i`, or `lxc exec --user` into an LXD VM — the process inherits a system service cgroup (e.g., `/system.slice/lxd-agent.service` or `/user.slice/.../session-XX.scope` under a foreign service). Snapd's `snap-confine` rejects snap execution from these cgroups with a cryptic error like `"/system.slice/lxd-agent.service is not a snap cgroup for tag snap.juju.juju"`. This affects all strictly-confined snaps — LXD's own `lxc` command only avoids this because the `lxd-support` super-privileged interface bypasses cgroup validation entirely. The wrapper detects this condition by checking `/proc/self/cgroup` for system service cgroup patterns and exits early with a human-readable message:
```
WARNING: This shell is not running in a regular login session.
Do not run the first 'juju deploy' under su or sudo.
Use SSH or log in directly as your user instead.
```
This check only runs when the wrapper is about to do real work (install or bootstrap), not on pass-through. Once setup is complete, the wrapper does `exec /snap/bin/juju` transparently — at that point, any cgroup error comes from snapd itself and is outside the wrapper's control.

**Socket access check:** The wrapper checks if `/run/juju-installer.socket` is writable. If not, it prints:
```
Unable to trigger the installation of Juju.
Please make sure you're a member of the 'lxd' system group.
Run: sudo adduser $USER lxd && newgrp lxd
```
and exits 1. This mirrors lxd-installer's behavior.

**Group membership context:** On cloud/server images, cloud-init adds the default user to the `lxd` group automatically (via `/etc/cloud/cloud.cfg`). On desktop installs, the user must be added manually. Since `juju-installer` depends on `lxd-installer`, the `lxd` group is guaranteed to exist.

The wrapper handles four scenarios:

**Scenario 1: Juju snap not installed, non-deploy command**
- User runs `juju help`, `juju version`, etc.
- Wrapper confirms request: `Would you like to install Juju snap now (Y/n)?`
- Wrapper sends `i` to socket → service installs juju snap (+ ensures LXD ready)
- Waits up to 90s for `/snap/bin/juju` to appear
- `exec /snap/bin/juju "$@"`

**Scenario 2: Juju snap not installed, deploy command**
- User runs `juju deploy postgresql`
- Wrapper confirms request: `Would you like to install Juju snaps now (Y/n)?`
- Wrapper sends `i` to socket → service installs juju snap (+ ensures LXD ready)
- Waits up to 90s for snap to appear
- Wrapper runs `juju bootstrap lxd lxd` as current user (up to 10min)
- Wrapper runs `juju add-model welcome` as current user
- `exec /snap/bin/juju "$@"`

**Scenario 3: Juju snap installed, deploy command, no controller**
- User previously ran `juju help` (snap installed) but now runs `juju deploy postgresql`
- Wrapper detects no `lxd` controller exists
- Wrapper runs `juju bootstrap lxd lxd` as current user (no socket needed)
- Wrapper runs `juju add-model welcome` as current user
- `exec /snap/bin/juju "$@"`

**Scenario 4: Everything ready**
- Snap exists, controller exists
- `exec /snap/bin/juju "$@"` — zero overhead pass-through
- no extra output from wrapper (invisible pass-through)

### Progress Display

Progress comes from two sources: the service (steps 1-3) and the wrapper (steps 4-5).

**Service → wrapper communication:** The service writes progress lines to stdout (the socket). The wrapper reads these lines as they arrive and displays them. No shared files are used — all progress flows through the socket connection, avoiding race conditions and symlink attacks.

**Wrapper steps (4-5):** The wrapper writes its own progress directly to the terminal after the service completes.

Single overwriting line via `\r` — shows current step, each new step overwrites the previous (Canonical craft-tools style):
  ```
  \r[1/5] Preparing Juju environment (this may take a few minutes)...
  \r[2/5] Installing LXD...
  \r[3/5] Initializing LXD...
  \r[4/5] Bootstrapping Juju controller (this may take a few minutes)...
  \r[5/5] Creating welcome model...
  Hint: run 'juju status' to track deployment progress.
  ```
- Steps 1-3 run as root in the service; steps 4-5 run as the user in the wrapper

The wrapper reads progress lines from the socket using `recv()` in a loop until it receives the final `1` completion byte. This replaces the earlier polling-based approach.

### Service Script (`juju-installer-service`)

Runs as root via socket activation. Reads one byte from stdin (mode `i` or `b` — currently treated identically; the distinction exists for future use).

The service handles **only system-level operations** that require root. User-level operations (bootstrap, model creation) happen in the wrapper.

**Steps (all idempotent — each checks preconditions before acting):**

1. **Install Juju snap** — `snap install juju` (default track). Skip if `/snap/bin/juju` exists. Write progress: `[1/3] Installing Juju snap...`
2. **Ensure LXD snap is available** — if `/snap/bin/lxd` doesn't exist, trigger LXD installation by connecting to `/run/lxd-installer.socket` and sending one byte (the same protocol the lxd wrapper scripts use). Note: `systemctl start` on a socket unit does not trigger the associated service — a client must connect. Wait up to 90s for `/snap/bin/lxd` to appear. Write progress: `[2/3] Installing LXD...`
3. **Initialize LXD** — run `lxd init --auto` if no default storage pool exists. Detection: `/snap/bin/lxc storage list --format csv 2>/dev/null | grep -q default`. Write progress: `[3/3] Initializing LXD...`
4. Write `1` to stdout (signals completion to wrapper).

If any step fails, the service exits non-zero and the error is logged to the journal (`StandardError=journal`). The socket connection closes without sending the `1` completion byte — the wrapper detects this via EOF on `recv()` and reports the failure. No partial state needs cleanup — re-running the command retries from the failed step since each step's precondition check skips already-completed work.

### Bootstrap Logic (in the wrapper, as current user)

After the service completes and `/snap/bin/juju` is available, the wrapper performs user-level setup for `deploy` commands:

1. **Bootstrap Juju controller** — `timeout 600 /snap/bin/juju bootstrap lxd lxd`. Skip if a controller named `lxd` already exists. Detection: `/snap/bin/juju controllers --format json 2>/dev/null | grep -q '"lxd"'`. Display: `[4/5] Bootstrapping Juju controller (this may take a few minutes)...`
2. **Create welcome model** — `timeout 60 /snap/bin/juju add-model welcome`. Skip if model `welcome` already exists. Detection: `/snap/bin/juju models --format json 2>/dev/null | grep -q '"welcome"'`. Display: `[5/5] Creating welcome model...`

These run as the calling user, so `~/.local/share/juju` is populated correctly without any chown or JUJU_DATA overrides.

If either step fails or times out, the wrapper prints the error and exits non-zero. Re-running the command resumes from the failed step — the bootstrap check detects the existing controller (if step 1 succeeded) and skips to step 2.

After a successful deploy following bootstrap, the wrapper prints: `Hint: run 'juju status' to track deployment progress.` This hint only appears when bootstrap was performed — on pass-through (scenario 4), the wrapper is completely silent.

### Systemd Units

**`juju-installer.socket`:**
```ini
[Unit]
Description=Helper to install and bootstrap Juju on demand

[Socket]
ListenStream=/run/juju-installer.socket
SocketUser=root
SocketGroup=lxd
SocketMode=0660
Accept=true
MaxConnections=1

[Install]
WantedBy=multi-user.target
```

`MaxConnections=1` prevents concurrent service instances. If a second user triggers the socket while installation is in progress, their connection queues until the first completes. This avoids parallel `snap install` or `lxd init` races.

**`juju-installer@.service`:**
```ini
[Unit]
Description=Helper to install and bootstrap Juju on demand

[Service]
ExecStart=/bin/sh -eu /usr/share/juju-installer/juju-installer-service
StandardInput=socket
StandardOutput=socket
StandardError=journal
Restart=no
TimeoutStartSec=600
ProtectHome=yes
PrivateTmp=yes
```

### Debian Packaging

**`debian/postinst`:**
- Enable and start `juju-installer.socket`
- (POC1: no group creation — relies on `lxd` group from lxd-installer)

**`debian/prerm`:**
- Stop and disable `juju-installer.socket`

**`debian/postrm`:**
- On purge: remove `/run/juju-installer.socket` if present

## Security Considerations

1. **No user data crosses the privilege boundary.** The socket receives exactly one byte (`i` or `b`). All commands in the service script are hardcoded. No injection surface.
2. **Socket access control.** Only `root` and `lxd` group members can connect (`root:lxd`, mode `0660`).
3. **Idempotent operations.** Re-triggering the service is safe — every step checks preconditions before acting.
4. **No ARGV pass-through.** User's `juju` arguments (`deploy postgresql --channel 14/edge`) stay in userspace and are passed to `/snap/bin/juju` via `exec` after setup completes. They never touch the socket or the root-running service.
5. **Clean privilege split.** Root-requiring operations (snap install, LXD init) run in the service. User-level operations (juju bootstrap, model creation) run in the wrapper as the calling user. No need to pass usernames or home paths across the privilege boundary.

## Timeouts

| Operation | Where it runs | Timeout | Mechanism |
|-----------|--------------|---------|-----------|
| Service total (snap install + LXD + init) | Service (root) | 600s | `TimeoutStartSec` in service unit |
| LXD snap install | Service (root), via lxd-installer | 90s | lxd-installer's own timeout |
| `lxd init --auto` | Service (root) | included in service timeout | `TimeoutStartSec` |
| `juju bootstrap lxd lxd` | Wrapper (user) | 600s | `timeout 600` command |
| `juju add-model welcome` | Wrapper (user) | 60s | `timeout 60` command |
| Wrapper wait for snap to appear | Wrapper (user) | 90s | poll loop with counter |

The wrapper enforces timeouts on user-side operations using `timeout(1)`. If any step times out, the wrapper prints an error and exits non-zero. Re-running the command resumes from the failed step (see Resilience and Recovery).

## Scope and Limitations

- **LXD-only for MVP.** Only bootstraps a `localhost` (LXD) cloud. No MicroK8s/K8s support in this version.
- **Default snap tracks only.** Uses `snap install juju` and `snap install lxd` with default channels. No channel selection.
- **Not for experts.** This is a "try it" tool for newcomers. Users who need custom clouds, channels, or configurations should install Juju directly.
- **Ubuntu 24.04+ target.** Depends on `lxd-installer` being available (shipped since 24.04).

## Future Work (Out of Scope)

- **PoC2:** Dedicated `juju` system group instead of reusing `lxd` group
- **K8s support:** `juju deploy postgresql-k8s --trust` with Canonical K8s auto-setup
- **Channel selection:** Allow configuring snap channels via a config file
- **Integration with Ubuntu installer:** Pre-seed `juju-installer` in Ubuntu Server task list

## Testing Strategy

1. **Unit tests:** Test the wrapper script logic in isolation (mock `/snap/bin/juju` existence)
2. **Integration tests:** Run in a fresh LXD container or VM:
   - Fresh Ubuntu 24.04 → `juju deploy postgresql` → verify PostgreSQL charm is deployed
   - Fresh Ubuntu 24.04 → `juju version` → verify only snap install (no bootstrap)
   - Repeat tests above on Ubuntu 26.04
   - Pre-installed snap → `juju deploy postgresql` → verify bootstrap only
   - Fully set up → `juju deploy postgresql` → verify zero-overhead pass-through
3. **Security tests:** Verify non-lxd-group users cannot trigger the socket
4. **Idempotency tests:** Run the service multiple times, verify no errors or duplicate resources
