#!/bin/bash
# migrate-to-podman.sh — Replace Docker CE with Podman on the bootstrap host.
#
# Run as root after bootstrap.sh completes:
#   cd /root/bootstrap && ./migrate-to-podman.sh
#
# What this does:
#   1. Stops Docker (terminates any running containers, including the PXE stack).
#   2. Removes Docker CE packages.
#   3. Wipes /var/lib/docker to reclaim disk (optional — set KEEP_DOCKER_STATE=1
#      to skip).
#   4. Installs Podman from the local Rocky AppStream repo configured by
#      bootstrap.sh.
#   5. Loads the ansible-runner image into Podman from the local tarball
#      (docker save and podman load share the OCI tarball format).
#
# Caveats:
#   - The PXE container stack (pxe-dhcp / pxe-tftp / pxe-http) is launched by
#     the pxe_server Ansible role via `docker compose`. After this script
#     runs, that stack stops working. Re-implementing it on Podman is a
#     separate piece of work (podman-compose, Quadlet units, or systemd
#     services).
#   - Future ansible-runner invocations must use `podman run` instead of
#     `docker run`. The bootstrap.sh playbook step has already executed once
#     during the original bootstrap, so this only affects re-runs.
#   - This is a one-shot migration script, not an idempotent reconverge tool.
#     It is safe to re-run (each step skips when already in the desired
#     state), but a long-term fix should live in Ansible (rule #11).

set -euo pipefail

# ── Config ────────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE_TAR="${SCRIPT_DIR}/files/images/ansible-runner.tar"
ANSIBLE_IMAGE="mma38e/ansible-runner:latest"

DOCKER_PKGS=(
    docker-ce
    docker-ce-cli
    containerd.io
    docker-compose-plugin
    docker-buildx-plugin
)

# ── Helpers ───────────────────────────────────────────────────────────────────

log()  { echo "[migrate] $*"; }
die()  { echo "[migrate] ERROR: $*" >&2; exit 1; }

# ── Preflight ────────────────────────────────────────────────────────────────

[[ "$(id -u)" -eq 0 ]] || die "Must be run as root"

if ! grep -qi "rocky" /etc/os-release 2>/dev/null; then
    die "This script targets Rocky Linux 9.x only"
fi

[[ -f "${IMAGE_TAR}" ]] || die "ansible-runner tarball not found: ${IMAGE_TAR}"

# ── Step 1: Stop Docker ──────────────────────────────────────────────────────

if systemctl is-active docker &>/dev/null; then
    log "Stopping docker.service + docker.socket (running containers will exit)..."
    systemctl stop docker.socket docker.service 2>/dev/null || true
else
    log "Docker is not running — skipping stop"
fi

if systemctl is-enabled docker &>/dev/null; then
    log "Disabling docker.service + docker.socket..."
    systemctl disable docker.socket docker.service 2>/dev/null || true
fi

# ── Step 2: Remove Docker CE packages ───────────────────────────────────────

TO_REMOVE=()
for pkg in "${DOCKER_PKGS[@]}"; do
    rpm -q "${pkg}" &>/dev/null && TO_REMOVE+=("${pkg}")
done

if [[ ${#TO_REMOVE[@]} -gt 0 ]]; then
    log "Removing Docker CE packages: ${TO_REMOVE[*]}"
    dnf remove -y "${TO_REMOVE[@]}"
else
    log "No Docker CE packages installed — skipping removal"
fi

# ── Step 3: Wipe /var/lib/docker (optional) ─────────────────────────────────

# Set KEEP_DOCKER_STATE=1 to preserve image/container storage for rollback.
if [[ -d /var/lib/docker && "${KEEP_DOCKER_STATE:-0}" != "1" ]]; then
    log "Removing /var/lib/docker (set KEEP_DOCKER_STATE=1 to preserve)..."
    rm -rf /var/lib/docker
fi

# ── Step 4: Install Podman ──────────────────────────────────────────────────

if rpm -q podman &>/dev/null; then
    log "Podman already installed — skipping"
else
    log "Installing podman from local Rocky AppStream repo..."
    dnf install -y podman
fi

# ── Step 5: Load ansible-runner into Podman ─────────────────────────────────

if podman image exists "${ANSIBLE_IMAGE}" 2>/dev/null; then
    log "ansible-runner already present in Podman storage — skipping load"
else
    log "Loading ansible-runner from ${IMAGE_TAR} into Podman..."
    podman load -i "${IMAGE_TAR}"
fi

# ── Verify ──────────────────────────────────────────────────────────────────

log ""
log "Migration complete. Quick verification:"
log "  podman images                                          # should list ${ANSIBLE_IMAGE}"
log "  podman run --rm ${ANSIBLE_IMAGE} ansible --version     # smoke-test the runner"
log ""
log "Reminder: any future ansible-runner re-runs need 'podman run' (not 'docker run')."
log "          The PXE container stack is offline until rebuilt on Podman."
