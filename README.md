# juju-installer

A lightweight Debian package that enables a one-command Juju experience on Ubuntu.

Instead of manually installing snaps, initializing substrates, bootstrapping controllers, and creating models, users can simply run:

```bash
juju deploy postgresql              # LXD substrate
juju deploy postgresql-k8s --trust  # Canonical K8s substrate
```

On a fresh Ubuntu 24.04+ system, `juju-installer` handles everything automatically:
installing the required snaps, initializing the substrate (LXD or Canonical K8s),
bootstrapping a Juju controller, creating a model, and executing the deploy.

[![asciicast](https://asciinema.org/a/dTK6RJteUDDatNTX.svg)](https://asciinema.org/a/dTK6RJteUDDatNTX)

## How It Works

`juju-installer` follows the same pattern as Ubuntu's
[`lxd-installer`](https://launchpad.net/ubuntu/+source/lxd-installer) package:

1. A thin wrapper script at `/sbin/juju` intercepts `juju` commands
2. If the Juju snap is not installed, it detects the target substrate from the
   charm name (`-k8s` suffix → Canonical K8s, otherwise → LXD)
3. It triggers the appropriate systemd socket-activated service (no `sudo` required):
   snap-only, LXD, or K8s
4. For `juju deploy` commands, the wrapper also bootstraps the Juju controller
   as the calling user
5. Once setup is complete, the wrapper passes through to the real
   `/snap/bin/juju` with zero overhead

### Privilege Split

- **Root operations** (via systemd socket): `snap install juju`, `snap install lxd`, `lxd init --auto`, `snap install k8s`, `k8s bootstrap`, `k8s enable local-storage`
- **User operations** (in the wrapper): `juju bootstrap`, `juju add-k8s`, `juju add-model welcome`

No user-controlled data crosses the privilege boundary. The socket is a trigger,
not a command channel.

## Requirements

- Ubuntu 24.04 (Noble) or later
- `lxd-installer` package (pulled in as a dependency)
- User must be a member of the `lxd` system group

## Installation

### From PPA (recommended)

```bash
sudo add-apt-repository ppa:taurus/juju-installer
sudo apt update
sudo apt install juju-installer
```

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
# Deploy a VM charm (triggers LXD setup on first run)
juju deploy postgresql

# Deploy a K8s charm (triggers Canonical K8s setup on first run)
juju deploy postgresql-k8s --trust

# Run any juju command (triggers snap install only)
juju version
juju help
```

## Package Contents

```
/sbin/juju                                                  # wrapper script
/usr/lib/systemd/system/juju-installer-snap.socket          # snap-only socket
/usr/lib/systemd/system/juju-installer-snap@.service        # snap-only service
/usr/lib/systemd/system/juju-installer-lxd.socket           # LXD socket
/usr/lib/systemd/system/juju-installer-lxd@.service         # LXD service
/usr/lib/systemd/system/juju-installer-k8s.socket           # K8s socket
/usr/lib/systemd/system/juju-installer-k8s@.service         # K8s service
/usr/share/juju-installer/juju-installer-snap-service       # snap install logic
/usr/share/juju-installer/juju-installer-lxd-service        # LXD install/init logic
/usr/share/juju-installer/juju-installer-k8s-service        # K8s install/bootstrap logic
```

## Design

See [docs/specs/2026-05-11-juju-installer-design.md](docs/specs/2026-05-11-juju-installer-design.md)
for the PoC1 (LXD support) design and [docs/specs/2026-05-12-poc2-k8s-support-design.md](docs/specs/2026-05-12-poc2-k8s-support-design.md)
for the PoC2 (K8s support) design.

## Future Work

- Dedicated `juju` system group (instead of reusing `lxd`)
- Charmhub API detection (query charm metadata instead of name suffix)
- Re-bootstrap after snap already installed
- Configurable snap channels
- CI/CD via GitHub Actions

## Contributing

This project is part of [Canonical](https://canonical.com/).
Contributions are welcome via pull requests.

## License

Copyright 2026 Canonical Ltd.

Licensed under the Apache License, Version 2.0. See [LICENSE](LICENSE) for details.
