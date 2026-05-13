# Integration test workflow for juju-installer

**Date**: 2026-05-13
**Status**: Draft

## Goal

Add a GitHub Actions workflow that installs juju-installer from the PPA and
runs the full end-to-end flow (snap install, substrate init, bootstrap,
deploy) on a GitHub runner. Two parallel jobs: LXD and Canonical K8s.

## Constraints

- Free GitHub runners: 2 vCPUs, 7 GB RAM, `ubuntu-latest` (24.04).
- LXD path should work on these runners. K8s path will likely fail due to
  resource constraints — marked `continue-on-error: true`.
- PPA: `ppa:taurus/juju-installer`.

## File

```
.github/workflows/integration.yml
```

## Triggers

- `schedule: cron '42 3 * * 5'` — Friday 03:42 UTC (alongside weekly unit
  tests).
- `workflow_dispatch` — manual trigger from GitHub UI.

## Job 1: integration-lxd

Runs on `ubuntu-latest`. Timeout: 20 minutes.

Steps:

1. **Add PPA and install**:
   ```bash
   sudo add-apt-repository -y ppa:taurus/juju-installer
   sudo apt-get update
   sudo apt-get install -y juju-installer
   ```

2. **Configure LXD group membership**:
   ```bash
   sudo adduser "$(whoami)" lxd
   ```

3. **Enable systemd sockets**:
   ```bash
   sudo systemctl enable --now juju-installer-snap.socket
   sudo systemctl enable --now juju-installer-lxd.socket
   ```

4. **Run juju deploy** (triggers full LXD flow):
   ```bash
   sg lxd -c 'juju deploy postgresql'
   ```
   Uses `sg lxd` to pick up group membership without requiring a new login
   session. The `postgresql` charm is the canonical example from the
   README and exercises the standard LXD deploy path.

5. **Verify juju status**:
   ```bash
   sg lxd -c 'juju status'
   ```
   Verify the command exits 0 and output contains a controller and model.

## Job 2: integration-k8s

Runs on `ubuntu-latest`. Timeout: 30 minutes. `continue-on-error: true`.

Steps:

1. **Add PPA and install** (same as LXD job).

2. **Configure LXD group membership** (same — sockets use `lxd` group).

3. **Enable systemd sockets**:
   ```bash
   sudo systemctl enable --now juju-installer-snap.socket
   sudo systemctl enable --now juju-installer-k8s.socket
   ```

4. **Run juju deploy** (triggers full K8s flow):
   ```bash
   sg lxd -c 'juju deploy postgresql-k8s --trust'
   ```
   The K8s flow installs the Juju and Canonical K8s snaps, bootstraps K8s,
   waits for ready, enables local storage, exports kubeconfig, registers
   the cloud, bootstraps a Juju controller, and creates a model.

5. **Verify juju status**:
   ```bash
   sg lxd -c 'juju status'
   ```

This job is expected to fail on free runners (2 vCPU / 7 GB) since
Canonical K8s recommends 8 CPU / 16 GB. It exists to validate the flow
when larger runners become available.

## Success criteria

- LXD job: `juju status` exits 0 and shows a controller.
- K8s job: same, but `continue-on-error: true` so failures do not block.

## Out of scope

- Deploying and waiting for charm to become active (too slow for CI).
- Testing on Ubuntu 26.04 (not available as a runner image yet).
- Self-hosted or larger runners (can be added later by changing
  `runs-on`).
