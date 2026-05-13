# Progress streaming protocol for socket-activated services

**Date**: 2026-05-13
**Status**: Draft

## Goal

Make per-step progress from the three socket-activated service scripts
(`share/juju-installer-snap-service`, `juju-installer-lxd-service`,
`juju-installer-k8s-service`) visible in the user's terminal during the
long bootstrap phase, instead of being silently captured by the systemd
journal.

## Current state

The wrapper `sbin/juju` triggers each service through a Unix socket
protocol that exchanges exactly two bytes:

```
wrapper                          service script
─────                            ──────────────
connect()                        forked by systemd-socket-activated@N.service
send "i"          ─────►        read mode byte (head -c1)
                                 (do work; print [N/M] progress to stderr)
                  ◄─────        echo 1   ← completion sentinel (stdout = socket)
recv(1)
```

Service scripts emit `[N/M]` progress lines to *stderr*, and
`systemd/juju-installer-*@.service` files route `StandardError=journal`.
Net effect: the entire snap-install + substrate-bootstrap phase
(typically minutes for K8s) is silent to the user. After this phase,
the wrapper paints `[7/9]…[9/9]` itself, and on re-runs the conditional
`has_*` checks skip most of those — so users can legitimately see only
`[1/9]` (a long pause) followed by `[8/9]`.

The K8s flow is the most painful (5–10 min silent phase). LXD has the
same architectural blind spot but is fast enough that it usually feels
acceptable.

## Goals

- Stream every service-side milestone to the user's terminal as it happens.
- Keep the project's design constraints: POSIX sh, no new `Depends:`,
  scripts remain "the documentation".
- Match the existing UX: a single rolling progress line that updates
  via `\r`, not a scrollback log.
- Distinguish three failure modes (clean, dirty, unreachable) and
  produce actionable error output for the dirty case.

## Non-goals

- Replacing systemd socket activation with FIFOs, dbus, or a different
  IPC mechanism.
- Removing `python3` from `Depends:` (it is also used by
  `share/juju-installer-lxd-service` to talk to `lxd-installer.socket`,
  so the dep cannot be eliminated regardless).
- Relaying underlying tool chatter (snap install progress bars,
  k8s bootstrap output). Those stay in the journal.
- Adding a wrapper-side timeout (the systemd unit's `TimeoutStartSec=900`
  already covers stuck services and surfaces as EOF on the socket).
- Auto-retry on failure (would re-run half-applied install steps).
- Bumping the K8s denominator from `9` to `10`. Step 8 is the
  "set up Juju controller" phase; cloud-register and controller-bootstrap
  are sub-steps that share the `[8/9]` label and update only the
  descriptive text. Acceptable under the rolling-line UX.

## Design

### Wire protocol

The bidirectional Unix socket carries a line-oriented byte stream.

```
wrapper                                       service script
─────                                         ──────────────
connect()                                     (forked by systemd@N)
send "i"                ───────►              read mode byte
                                              for each milestone:
                        ◄───────              printf "[N/M] ...\n"   (stdout = socket)
                                              (snap/k8s chatter → stderr → journal)
                        ◄───────              printf "ERROR: ...\n"  (on error, before exit)
                        ◄───────              echo 1                 (terminator)
read line "[N/M] ..." → show_progress
read line "1"         → return 0
read EOF without "1"  → fail loudly
```

**Three guarantees:**

1. **One milestone per line.** Service uses a single `printf '[N/M] ...\n'`
   per milestone; sh `printf` is atomic at this size.
2. **Terminator is a single line `1\n`.** Milestone lines never collide
   because they all start with `[N/M] ...`.
3. **No tool chatter on the socket.** Each `snap install`, `k8s bootstrap`,
   `lxd init` invocation gets `>&2 2>&1` (today they're `1>&2`, which
   leaks tool stdout to the socket — currently invisible because the
   wrapper closed after recv(1), but a real bug under the new protocol).

### Step labels

K8s flow becomes a coherent `[1/9]…[9/9]` sequence:

| # | Owner | Label |
|---|---|---|
| 1 | wrapper (before trigger) | Preparing Juju environment... |
| 2 | service | Installing Juju snap... |
| 3 | service | Installing Canonical K8s... |
| 4 | service | Bootstrapping Canonical K8s... |
| 5 | service | Waiting for K8s to be ready... |
| 6 | service | Enabling local-storage... |
| 7 | service | Exporting kubeconfig... |
| 8 | wrapper (do_bootstrap_k8s) | Registering K8s cloud... → Bootstrapping Juju controller... (two sub-steps, both labeled `[8/9]`, descriptive text updates between them) |
| 9 | wrapper (do_bootstrap_k8s) | Creating welcome model... |

LXD flow becomes `[1/5]`:

| # | Owner | Label |
|---|---|---|
| 1 | wrapper (before trigger) | Preparing Juju environment... |
| 2 | service | Installing Juju snap... |
| 3 | service | Installing LXD / Initializing LXD... |
| 4 | wrapper (do_bootstrap_lxd) | Bootstrapping Juju controller... |
| 5 | wrapper (do_bootstrap_lxd) | Creating welcome model |

Snap-only stays `[1/1]` (single step, all on the service side).
This label is visible to users for the first time under the new
protocol — today it's printed by the service script but routed to
the journal.

### Wrapper changes (`sbin/juju`)

**New helper `relay_progress`** replaces the body of all three
`trigger_*_service` functions. Inline `python3 -c` (existing dep, ~12
lines), self-contained, security surface unchanged from current
inline-Python uses:

```sh
relay_progress() {
    PYSOCK="$1" PYUNIT="$2" python3 -c '
import os, socket, sys
s = socket.socket(socket.AF_UNIX)
try:
    s.connect(os.environ["PYSOCK"])
except (FileNotFoundError, ConnectionRefusedError) as e:
    sys.stderr.write("\r%-70s\r" % "")
    sys.stderr.write("ERROR: cannot reach %s. Is the package installed? "
                     "(sudo systemctl status %s.socket)\n"
                     % (os.environ["PYUNIT"], os.environ["PYUNIT"]))
    sys.exit(1)
s.send(b"i")
for raw in s.makefile("rb"):
    line = raw.rstrip(b"\n").decode("utf-8", "replace")
    if line == "1":
        sys.exit(0)
    sys.stderr.write("\r%-70s" % line[:70])
    sys.stderr.flush()
sys.stderr.write("\r%-70s\r" % "")
sys.stderr.write("ERROR: %s service exited unexpectedly. "
                 "Run: sudo journalctl -u %s@\\* -e\n"
                 % (os.environ["PYUNIT"], os.environ["PYUNIT"]))
sys.exit(1)
'
}
```

**`trigger_*_service` shrink to one-liners:**

```sh
trigger_snap_service() { relay_progress /run/juju-installer-snap.socket juju-installer-snap; }
trigger_lxd_service()  { relay_progress /run/juju-installer-lxd.socket  juju-installer-lxd;  }
trigger_k8s_service()  { relay_progress /run/juju-installer-k8s.socket  juju-installer-k8s;  }
```

**`do_bootstrap_k8s` labels:** both `if !has_k8s_cloud` and
`if !has_k8s_controller` blocks call `show_progress` with the same
`[8/9]` denominator and different descriptive text ("Registering
K8s cloud...", "Bootstrapping Juju controller..."). On a fresh
install they run sequentially under one shared step number; on a
re-run, whichever block's guard is false simply doesn't repaint.
`[9/9]` keeps its slot for `add-model welcome`.

### Service-script changes

For each of `share/juju-installer-{snap,lxd,k8s}-service`:

1. **Progress lines go to stdout (= socket), not stderr.**
   Change `echo "[N/M] ..." 1>&2` → `printf '[N/M] ...\n'`
   (drop the `1>&2` redirect; stdout is the socket per the unit file).
2. **Underlying tool output goes to journal.**
   `snap install juju 1>&2` → `snap install juju >&2 2>&1`.
   Same for `k8s bootstrap`, `k8s enable local-storage`, `k8s status`,
   `k8s config`, `lxd init`.
3. **Error lines go to stdout (= socket) too**, then exit non-zero
   without writing the terminator. Wrapper's relay surfaces both the
   service-specific ERROR line and the EOF-detected journal hint.
4. **Renumber labels** to the shared sequence above.

### Systemd units — no change

`StandardOutput=socket`, `StandardError=journal`,
`Accept=true`, `MaxConnections=1`, `TimeoutStartSec=900` all stay.
The new design works *because* of the existing routing.

### Debian packaging — no change

`python3` already in `Depends:`. No new files in `debian/install`.

## Error handling

| Failure | Wire signal | Wrapper response |
|---|---|---|
| Service ran cleanly | line `1\n` arrives | `relay_progress` returns 0; wrapper continues |
| Service died mid-step | EOF on socket without `1\n` first | clear progress; print "ERROR: <unit> service exited unexpectedly. Run: sudo journalctl -u <unit>@\* -e"; exit 1 |
| Socket can't be connected | `connect()` raises in Python | clear progress; print "ERROR: cannot reach <unit>. Is the package installed?"; exit 1 |

When a service writes its own `ERROR: ...` line before exiting, the
relay surfaces both messages — the service-specific error line first
(as a normal progress-style line), then the journal-hint tail. Two
lines total, both informative, no duplication.

The Python helper is exhaustive on exit paths: success (`1` seen),
EOF without terminator, or connect failure. No silent paths, no
swallowed exceptions. Each `trigger_*_service` call site uses
`|| exit 1` to propagate `relay_progress` failure to the wrapper, so
the user does not stare at a silent `wait_for_snap` loop for 90
seconds after an "exited unexpectedly" message.

## Concurrency and security

Unchanged from today.

- `Accept=true` + `MaxConnections=1` on each `*.socket` unit serializes
  bootstrap attempts. A second invocation blocks at `connect()` until
  the first finishes.
- The socket protocol still carries no user data across the privilege
  boundary; the wrapper sends one fixed mode byte (`i`), and the service
  doesn't parse anything from the socket beyond that one byte.
- `SocketUser=root`, `SocketGroup=lxd`, `SocketMode=0660` unchanged —
  user must still be in the `lxd` group to write to the socket.

## Testing

### Layer 1: Mock-service helper (new, in `tests/test_wrapper.sh`)

A ~20-line helper spawns a real Unix socket listener via inline
`python3` that replays a scripted line sequence. The current
sed-based stubbing of `trigger_*_service` is *removed* — the patched
wrapper exercises the real `relay_progress` against this mock.

```sh
start_mock_service() {
    SOCK="$1" SCRIPT="$2" python3 -c '
import os, socket
sock_path = os.environ["SOCK"]
try: os.unlink(sock_path)
except FileNotFoundError: pass
srv = socket.socket(socket.AF_UNIX); srv.bind(sock_path); srv.listen(1)
os.chmod(sock_path, 0o660)
conn, _ = srv.accept()
conn.recv(1)
with open(os.environ["SCRIPT"]) as f:
    for line in f:
        line = line.rstrip("\n")
        if line == "EOF": break
        conn.sendall((line + "\n").encode())
conn.close(); srv.close()
' &
    MOCK_PID=$!
}
```

### Layer 2: Wrapper test cases

| Test | Script lines | Assertion |
|---|---|---|
| `test_k8s_streams_all_steps` | `[2/9]…[7/9]…1` | stderr contains each `[N/9]` for N in 2..7 |
| `test_k8s_handles_clean_terminator` | `[2/9] foo`, `1` | wrapper proceeds to `do_bootstrap_k8s`; exit 0 |
| `test_relay_eof_without_terminator` | `[2/9] foo`, `EOF` | stderr contains "exited unexpectedly"; exit non-zero |
| `test_relay_socket_missing` | (don't start mock) | stderr contains "cannot reach"; exit non-zero |
| `test_service_error_line_relayed` | `ERROR: snap install failed`, `EOF` | stderr contains both the ERROR line and the journalctl hint |
| `test_lxd_streams_all_steps` | `[2/5]`, `[3/5]`, `1` | stderr contains [2/5], [3/5] |
| `test_snap_only_streams` | `[1/1]`, `1` | stderr contains [1/1] |

The existing `tests/test_wrapper.sh:469` test (`K8s path shows [1/9]`)
keeps passing — `[1/9]` is still wrapper-printed before the trigger.

### Layer 3: Service-script tests (`tests/test_services.sh`)

Per-service assertions that the script writes its progress to stdout
(not stderr), uses the new label sequence, and ends with `1\n`:

```sh
test_k8s_service_writes_progress_to_stdout() {
    PATH="${MOCK_BIN}:${PATH}" \
    printf 'i' | sh share/juju-installer-k8s-service >"$out" 2>"$err"
    grep -q '^\[2/9\] Installing Juju snap' "$out" || return 1
    grep -q '^1$'                            "$out" || return 1
    grep -qv 'snap install'                  "$out" || return 1   # chatter must not leak
}
```

The mock-binaries directory is the existing pattern in
`tests/test_services.sh` — no new infra.

### Out of scope

- Real systemd activation (manual VM testing covers this).
- Real snap install timing.
- `MaxConnections=1` concurrency (systemd's responsibility, not ours).

## Open questions

None at spec time. The wrapper-vs-service step boundaries, the
shared `[8/9]` label across the two `do_bootstrap_k8s` sub-steps,
and the reused `1\n` terminator have all been explicitly approved
during brainstorming.

## Migration notes

This is a coordinated wrapper + service-script change shipped together
in one Debian package. There is no in-place upgrade hazard: the
package replaces all four files atomically, and any in-flight
bootstrap on an older version completes (or fails) under its old
protocol before the new package's units take effect.

No protocol negotiation byte is needed; mode byte `i` retains its
meaning.
