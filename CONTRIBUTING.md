# Contributing to juju-installer

## Development

```bash
# Build the package
dpkg-buildpackage -us -uc

# Run tests
sh tests/test_wrapper.sh

# Install locally
sudo apt install ../juju-installer_*.deb
```

## Testing in a VM

```bash
lxc launch ubuntu:26.04 test --vm -c limits.cpu=4 -c limits.memory=8GiB
lxc file push ../juju-installer_*.deb test/tmp/
lxc exec test -- su -l ubuntu
# inside VM:
sudo apt install /tmp/juju-installer_*.deb
juju deploy postgresql
```

K8s path requires more resources (8 CPU, 16 GB RAM recommended).

## Pull Requests

- Run `sh tests/test_wrapper.sh` and confirm all tests pass before submitting.
- Follow existing commit message style: `feat:`, `fix:`, `chore:`, `test:`, `docs:`.
- Keep wrapper changes POSIX sh compatible (no bashisms).

## Architecture

See [PoC1 design](docs/specs/2026-05-11-juju-installer-design.md) and
[PoC2 design](docs/specs/2026-05-12-poc2-k8s-support-design.md) for technical details.

## License

By contributing, you agree that your contributions will be licensed under the Apache License 2.0.
