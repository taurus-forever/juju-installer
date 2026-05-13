# juju-installer

A Debian package that provides a one-command Juju experience on Ubuntu.
Modeled after Ubuntu's `lxd-installer` package. Part of Canonical; Apache 2.0
licensed.

## Design philosophy

The package is intentionally minimal:

- **As small as possible**: every line of code must earn its place. No bloat,
  no convenience wrappers that could be avoided.
- **No external dependencies**: the wrapper and service scripts rely only on
  coreutils, Python 3 (for socket activation), and the snaps they install.
  Never pull in extra packages.
- **Human-readable**: the shell scripts are the documentation. Anyone should be
  able to read `sbin/juju` top-to-bottom and understand the full flow without
  external context.

Prefer removing code over adding it. If a feature can be achieved without new
dependencies, that is the only acceptable path. If a change makes the scripts
harder to read at a glance, it needs to be simplified before merge.

## Canonical policies

- Ubuntu Code of Conduct applies to all contributions.
- External contributors must sign the Canonical CLA before contributing.
- All AI-generated code requires human review before merge.
- US English throughout (Canonical style guide). Write "for example" not
  "e.g.", "that is" not "i.e.".

## Architecture

- Thin wrapper at `/sbin/juju` intercepts commands before the Juju snap is
  installed.
- Three systemd socket-activated services: snap-only, LXD, Canonical K8s.
- Privilege split: root operations (snap install, substrate init) via systemd;
  user operations (bootstrap, add-model) in the wrapper.
- The socket is a trigger, not a command channel. No user-controlled data
  crosses the privilege boundary.

## Key files

```
sbin/juju                          # POSIX sh wrapper (main logic)
systemd/                           # Socket and service unit files
share/                             # Service scripts (snap, lxd, k8s)
debian/                            # Debian packaging
tests/test_wrapper.sh              # Shell unit tests
docs/specs/                        # Design specifications
```

## Language and conventions

- POSIX sh only. No bashisms: no arrays, no `[[ ]]`, no `local`, no process
  substitution, no `source`.
- `shellcheck`-clean.
- No comments unless explaining a non-obvious "why".
- Functions follow existing patterns: `show_progress`, `clear_progress`,
  `confirm_install`, `check_*`, `trigger_*_service`, `do_bootstrap_*`.

## Build

```sh
dpkg-buildpackage -us -uc
sudo apt install ../juju-installer_*.deb
```

## Test

```sh
sh tests/test_wrapper.sh
```

All tests must pass before any pull request. Tests mock snaps, sockets,
cgroups, and controller/cloud/model checks via environment variables and
sed-based patching.

## Documentation standards

Follow the Diataxis framework. Use plain language, sentence-case headings.

## Debian packaging

- `debian/control`: package metadata, dependencies, `Provides: juju`.
- `debian/changelog`: version history in Debian format.
- `debian/install`: maps source files to install locations.
- `debian/rules`: build rules (uses debhelper).
- Dependencies must stay minimal. Never add a new `Depends:` entry unless
  absolutely unavoidable. The current dependency list (`lxd-installer`,
  `python3`) is the ceiling, not the floor.

## Security constraints

- The socket is a trigger only. No user data crosses the privilege boundary.
- Never store secrets, tokens, or credentials in the wrapper.
- The wrapper never runs `sudo` directly. Privilege escalation is handled
  exclusively through systemd socket activation.
- Root detection: `juju deploy` blocks when run as root (UID 0).
- Cgroup detection: blocks execution from system services (non-interactive).

## Commit style

Conventional commits: `feat:`, `fix:`, `chore:`, `test:`, `docs:`.
