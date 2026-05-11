# juju-installer

A lightweight Debian package that enables a one-command Juju experience on Ubuntu.

Instead of manually installing snaps, initializing LXD, bootstrapping controllers, and creating models, users can simply run:

```bash
juju deploy postgresql
```

On a fresh Ubuntu 24.04+ system, `juju-installer` handles everything automatically:
installing the Juju and LXD snaps, initializing LXD, bootstrapping a Juju controller,
creating a model, and executing the deploy.

## How It Works

`juju-installer` follows the same pattern as Ubuntu's
[`lxd-installer`](https://launchpad.net/ubuntu/+source/lxd-installer) package:

1. A thin wrapper script at `/sbin/juju` intercepts `juju` commands
2. If the Juju snap is not installed, it triggers installation via a systemd
   socket-activated service (no `sudo` required)
3. For `juju deploy` commands, the wrapper also bootstraps LXD and the Juju
   controller as the calling user
4. Once setup is complete, the wrapper passes through to the real
   `/snap/bin/juju` with zero overhead

### Privilege Split

- **Root operations** (via systemd socket): `snap install juju`, `snap install lxd`, `lxd init --auto`
- **User operations** (in the wrapper): `juju bootstrap lxd lxd`, `juju add-model welcome`

No user-controlled data crosses the privilege boundary. The socket is a trigger,
not a command channel.

## Requirements

- Ubuntu 24.04 (Noble) or later
- `lxd-installer` package (pulled in as a dependency)
- User must be a member of the `lxd` system group

## Installation

### From .deb (local build)

```bash
sudo apt install ./juju-installer_*.deb
```

### From source

```bash
dpkg-buildpackage -us -uc
sudo apt install ../juju-installer_*.deb
```

## Usage

```bash
# Deploy a charm (triggers full setup on first run)
juju deploy postgresql

# Run any juju command (triggers snap install only)
juju version
juju help
```

## Package Contents

```
/sbin/juju                                        # wrapper script
/usr/lib/systemd/system/juju-installer.socket      # systemd socket unit
/usr/lib/systemd/system/juju-installer@.service     # systemd service unit
/usr/share/juju-installer/juju-installer-service    # install/bootstrap logic
```

## Design

See [docs/specs/2026-05-11-juju-installer-design.md](docs/specs/2026-05-11-juju-installer-design.md)
for the full design document.

## Future Work

- Dedicated `juju` system group (instead of reusing `lxd`)
- Canonical K8s support (`juju deploy postgresql-k8s --trust`)
- Configurable snap channels
- CI/CD via GitHub Actions

## Contributing

This project is part of [Canonical](https://canonical.com/).
Contributions are welcome via pull requests.

## License

Copyright 2026 Canonical Ltd.

Licensed under the Apache License, Version 2.0. See [LICENSE](LICENSE) for details.
