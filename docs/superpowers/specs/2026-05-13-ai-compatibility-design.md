# AI compatibility files for juju-installer

**Date**: 2026-05-13
**Status**: Draft

## Goal

Add AI coding assistant instruction files to juju-installer so that Claude Code
and GitHub Copilot can contribute safely and effectively, following Canonical's
software development policies.

## Scope

Three files in their standard locations:

| File | Tool | Purpose |
|---|---|---|
| `CLAUDE.md` | Claude Code | Project context, conventions, build/test |
| `AGENTS.md` | Claude Code | Specialized agent role definitions |
| `.github/copilot-instructions.md` | GitHub Copilot | Project context for code completion |

No new dependencies. No changes to existing code.

## Canonical policies to encode

Every instruction file must reflect these Canonical standards:

- **Ubuntu Code of Conduct**: collaborative, respectful, considerate
- **Canonical CLA**: external contributors sign before contributing
- **Human review**: all AI-generated code requires human review before merge
- **Canonical style guide**: US English, sentence case, plain language, no Latin
  abbreviations (e.g., use "for example" not "e.g.")
- **Diataxis framework**: documentation organized as tutorials, how-to guides,
  reference, or explanation
- **Security-first**: the privilege split (root via systemd sockets, user-space
  bootstrap) is a security boundary, not just convenience

## File 1: CLAUDE.md

Comprehensive project instructions for Claude Code. Sections:

### Project overview

- juju-installer is a Debian package that provides a one-command Juju experience
- Modeled after Ubuntu's `lxd-installer` package
- Part of Canonical; Apache 2.0 licensed

### Design philosophy

The package is intentionally minimal:
- **As small as possible**: every line of code must earn its place; no
  bloat, no convenience wrappers that could be avoided
- **No external dependencies**: the wrapper and service scripts rely only on
  coreutils, Python 3 (for socket activation), and the snaps they install;
  never pull in extra packages
- **Human-readable**: the shell scripts are the documentation; anyone should
  be able to read `sbin/juju` top-to-bottom and understand the full flow
  without external context

When contributing, prefer removing code over adding it. If a feature can be
achieved without new dependencies, that is the only acceptable path. If a
change makes the scripts harder to read at a glance, it needs to be
simplified before merge.

### Canonical policies

- Ubuntu Code of Conduct applies to all contributions
- External contributors must sign the Canonical CLA
- All AI-generated code requires human review before merge
- US English throughout (Canonical style guide)

### Architecture

- Thin wrapper at `/sbin/juju` intercepts commands before the snap is installed
- Three systemd socket-activated services: snap-only, LXD, Canonical K8s
- Privilege split: root operations (snap install, substrate init) via systemd;
  user operations (bootstrap, add-model) in the wrapper
- Socket is a trigger, not a command channel; no user-controlled data crosses
  the privilege boundary

### Key files

```
sbin/juju                          # POSIX sh wrapper (main logic)
systemd/                           # Socket and service unit files
share/                             # Service scripts (snap, lxd, k8s)
debian/                            # Debian packaging
tests/test_wrapper.sh              # Shell unit tests
docs/specs/                        # Design specifications
```

### Language and conventions

- POSIX sh only; no bashisms (no arrays, no `[[ ]]`, no `local`, no process
  substitution, no `source`)
- `shellcheck`-clean
- No comments unless explaining a non-obvious "why"
- Functions follow existing patterns: `show_progress`, `clear_progress`,
  `confirm_install`, `check_*`, `trigger_*_service`, `do_bootstrap_*`

### Build

```sh
dpkg-buildpackage -us -uc
sudo apt install ../juju-installer_*.deb
```

### Test

```sh
sh tests/test_wrapper.sh
```

All tests must pass before any pull request. Tests mock snaps, sockets,
cgroups, and controller/cloud/model checks via environment variables and
sed-based patching.

### Documentation standards

Follow the Diataxis framework. Use plain language, sentence-case headings.
Write "for example" not "e.g.", "that is" not "i.e.".

### Debian packaging

- `debian/control`: package metadata, dependencies, `Provides: juju`
- `debian/changelog`: version history in Debian format
- `debian/install`: maps source files to install locations
- `debian/rules`: build rules (uses debhelper)
- Dependencies must stay minimal; never add a new `Depends:` entry unless
  absolutely unavoidable. The current dependency list (`lxd-installer`,
  `python3`) is the ceiling, not the floor.

### Security constraints

- The socket is a trigger only; no user data crosses the privilege boundary
- Never store secrets, tokens, or credentials in the wrapper
- Validate that the wrapper never runs `sudo` directly; privilege escalation
  is handled exclusively through systemd socket activation
- Root detection: `juju deploy` blocks when run as root (UID 0)
- Cgroup detection: blocks execution from system services (non-interactive)

### Commit style

Conventional commits: `feat:`, `fix:`, `chore:`, `test:`, `docs:`.

## File 2: AGENTS.md

Three specialized agent roles:

### shell-reviewer

**Purpose**: enforce POSIX sh compliance and security boundary integrity.

**Responsibilities**:
- Run `shellcheck` on `sbin/juju` and `share/*`
- Check for bashisms: arrays, `[[ ]]`, `local` misuse, process substitution
- Validate that no user-controlled data crosses the socket privilege boundary
- Verify new functions follow existing naming patterns
- Flag US English violations (Canonical style guide)

### packager

**Purpose**: Debian packaging following Ubuntu archive standards.

**Responsibilities**:
- Validate `debian/control` dependencies and metadata
- Update `debian/changelog` with proper format and version bumping
- Ensure `debian/install` lists all shipped files
- Verify `debian/rules` compatibility with debhelper 13
- Check that new files have correct install paths
- Reject any new `Depends:` entries unless absolutely unavoidable; the
  package must stay minimal and dependency-free

### tester

**Purpose**: run and write tests following the existing mock infrastructure.

**Responsibilities**:
- Run `sh tests/test_wrapper.sh` and confirm all pass
- Write new test functions following the pattern:
  `setup -> patch_wrapper -> run_patched -> assert_* -> teardown`
- Use existing assertion functions: `assert_stderr_contains`,
  `assert_stderr_not_contains`, `assert_stdout_contains`
- Mock new functionality using environment variables and sed-based patching
- Group related tests under section headers (`echo "=== Section ==="`)

## File 3: .github/copilot-instructions.md

Concise project context for GitHub Copilot code completion:

- Project summary: intentionally minimal Debian package providing one-command
  Juju on Ubuntu, modeled after `lxd-installer`; no external dependencies,
  scripts must be human-readable top-to-bottom
- Language: POSIX sh only; no bashisms
- Architecture: wrapper at `/sbin/juju`, three systemd socket-activated
  services (snap, LXD, K8s), privilege split via sockets
- Build: `dpkg-buildpackage -us -uc`
- Test: `sh tests/test_wrapper.sh`
- Commits: conventional commits (`feat:`, `fix:`, `chore:`, `test:`, `docs:`)
- Canonical policies: Ubuntu Code of Conduct, CLA required for external
  contributors, human review required for all AI-generated code
- Security: sockets are triggers only, no user data crosses privilege boundary,
  never store secrets in the wrapper

## Out of scope

- Cursor rules (`.cursorrules`): not requested
- Gemini CLI (`GEMINI.md`): not requested
- CI/CD workflows: listed as future work in README, not part of this change
- Changes to existing code or tests
