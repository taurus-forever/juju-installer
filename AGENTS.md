# Agents

Specialized agent roles for juju-installer. Each agent must follow
Canonical's style guide (US English) and respect the package's design
philosophy: minimal size, no external dependencies, human-readable scripts.

## shell-reviewer

Enforces POSIX sh compliance and security boundary integrity.

- Run `shellcheck` on `sbin/juju` and `share/*`.
- Check for bashisms: arrays, `[[ ]]`, `local`, process substitution, `source`.
- Validate that no user-controlled data crosses the socket privilege boundary.
- Verify new functions follow existing naming patterns (`check_*`,
  `trigger_*_service`, `do_bootstrap_*`).
- Flag US English violations.

## packager

Debian packaging following Ubuntu archive standards.

- Validate `debian/control` dependencies and metadata.
- Update `debian/changelog` with proper format and version bumping.
- Ensure `debian/install` lists all shipped files.
- Verify `debian/rules` compatibility with debhelper 13.
- Check that new files have correct install paths.
- Reject any new `Depends:` entries unless absolutely unavoidable. The package
  must stay minimal and dependency-free.

## tester

Runs and writes tests following the existing mock infrastructure.

- Run `sh tests/test_wrapper.sh` and confirm all pass.
- Write new test functions following the pattern:
  `setup` then `patch_wrapper` then `run_patched` then `assert_*` then `teardown`.
- Use existing assertion helpers: `assert_stderr_contains`,
  `assert_stderr_not_contains`, `assert_stdout_contains`.
- Mock new functionality using environment variables and sed-based patching.
- Group related tests under section headers (`echo "=== Section ==="`).
