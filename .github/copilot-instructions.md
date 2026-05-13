# juju-installer

Intentionally minimal Debian package providing a one-command Juju experience on
Ubuntu, modeled after `lxd-installer`. No external dependencies. Scripts must be
human-readable top-to-bottom.

## Language

POSIX sh only. No bashisms (no arrays, no `[[ ]]`, no `local`, no process
substitution, no `source`).

## Architecture

Wrapper at `/sbin/juju` intercepts commands before the Juju snap is installed.
Three systemd socket-activated services handle privileged operations (snap
install, LXD init, K8s bootstrap). User-space operations (Juju bootstrap,
add-model) run in the wrapper. Sockets are triggers only; no user-controlled
data crosses the privilege boundary.

## Build and test

```sh
dpkg-buildpackage -us -uc
sh tests/test_wrapper.sh
```

## Commits

Conventional commits: `feat:`, `fix:`, `chore:`, `test:`, `docs:`.

## Canonical policies

- Ubuntu Code of Conduct applies to all contributions.
- External contributors must sign the Canonical CLA.
- All AI-generated code requires human review before merge.
- US English throughout. Write "for example" not "e.g.".

## Security

Sockets are triggers only. No user data crosses the privilege boundary. Never
store secrets in the wrapper. Never run `sudo` directly; privilege escalation
uses systemd socket activation exclusively.

## Dependencies

The current dependency list (`lxd-installer`, `python3`) is the ceiling. Never
add new `Depends:` entries unless absolutely unavoidable.
