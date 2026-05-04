#!/bin/bash
# migrate-to-docker.sh — Restore Docker CE on the bootstrap host.
#
# This is the rollback partner for migrate-to-podman.sh — band-aid coming
# off. Run as root after the temporary Podman period:
#   cd /root/bootstrap && ./migrate-to-docker.sh
#
# What this does:
#   1. Stops Podman API socket + any running Podman containers.
#   2. Removes Podman packages.
#   3. Wipes /var/lib/containers (set KEEP_PODMAN_STATE=1 to preserve).
#   4. Installs Docker CE from the local RPMs in files/rpms/docker/.
#   5. Enables and starts docker.service.
#   6. Loads ansible-runner from the local tarball into Docker.
#
# Notes:
#   - Symmetric to migrate-to-podman.sh. Neither lives in the baseline; both
#     are temporary tooling for a specific service workaround.
#   - After Docker is back, re-run the Ansible playbook to restore the PXE
#     container stack (pxe-dhcp / pxe-tftp / pxe-http).
#   - If the local repos that bootstrap.sh configured (local-baseos /
#     local-appstream from /etc/yum.repos.d/) have been removed, dnf may fail
#     to resolve Docker's transitive deps. They should still be present in
#     the standard post-bootstrap state.

set -euo pipefail

# ── Config ────────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RPM_DIR="${SCRIPT_DIR}/files/rpms"
IMAGE_TAR="${SCRIPT_DIR}/files/images/ansible-runner.tar"
ANSIBLE_IMAGE="mma38e/ansible-runner:latest"

PODMAN_PKGS=(
    podman
    podman-docker
    podman-plugins
    podman-remote
)

# ── Helpers ───────────────────────────────────────────────────────────────────

log()  { echo "[migrate-back] $*"; }
die()  { echo "[migrate-back] ERROR: $*" >&2; exit 1; }

# ── Preflight ────────────────────────────────────────────────────────────────

[[ "$(id -u)" -eq 0 ]] || die "Must be run as root"

if ! grep -qi "rocky" /etc/os-release 2>/dev/null; then
    die "This script targets Rocky Linux 9.x only"
fi

[[ -f "${IMAGE_TAR}" ]] || die "ansible-runner tarball not found: ${IMAGE_TAR}"

DOCKER_RPMS=("${RPM_DIR}"/docker/*.rpm)
[[ -e "${DOCKER_RPMS[0]}" ]] || die "No Docker RPMs found in ${RPM_DIR}/docker/"

# ── Step 1: Stop Podman ──────────────────────────────────────────────────────

# Podman is daemonless; the only persistent units are the API socket and the
# auto-restart service. Stopping them is harmless if not active.
for unit in podman.socket podman.service podman-restart.service; do
    if systemctl is-active "${unit}" &>/dev/null; then
        log "Stopping ${unit}..."
        systemctl stop "${unit}" 2>/dev/null || true
    fi
    if systemctl is-enabled "${unit}" &>/dev/null; then
        log "Disabling ${unit}..."
        systemctl disable "${unit}" 2>/dev/null || true
    fi
done

# Stop any running rootful containers before package removal.
if command -v podman &>/dev/null; then
    if [[ -n "$(podman ps -q 2>/dev/null || true)" ]]; then
        log "Stopping running Podman containers..."
        podman stop --all --time 10 2>/dev/null || true
    fi
fi

# ── Step 2: Remove Podman packages ──────────────────────────────────────────

TO_REMOVE=()
for pkg in "${PODMAN_PKGS[@]}"; do
    rpm -q "${pkg}" &>/dev/null && TO_REMOVE+=("${pkg}")
done

if [[ ${#TO_REMOVE[@]} -gt 0 ]]; then
    log "Removing Podman packages: ${TO_REMOVE[*]}"
    dnf remove -y "${TO_REMOVE[@]}"
else
    log "No Podman packages installed — skipping removal"
fi

# ── Step 3: Wipe /var/lib/containers (optional) ─────────────────────────────

if [[ -d /var/lib/containers && "${KEEP_PODMAN_STATE:-0}" != "1" ]]; then
    log "Removing /var/lib/containers (set KEEP_PODMAN_STATE=1 to preserve)..."
    rm -rf /var/lib/containers
fi

# ── Step 4: Install Docker CE ──────────────────────────────────────────────

if rpm -q docker-ce &>/dev/null; then
    log "Docker CE already installed — skipping"
else
    log "Installing Docker CE from local RPMs..."
    dnf localinstall -y --skip-broken "${DOCKER_RPMS[@]}"
fi

# ── Step 5: Enable + start Docker ──────────────────────────────────────────

log "Enabling and starting docker.service..."
systemctl enable --now docker

# ── Step 6: Load ansible-runner into Docker ─────────────────────────────────

if docker image inspect "${ANSIBLE_IMAGE}" &>/dev/null; then
    log "ansible-runner already present in Docker storage — skipping load"
else
    log "Loading ansible-runner from ${IMAGE_TAR} into Docker..."
    docker load < "${IMAGE_TAR}"
fi

# ── Verify ──────────────────────────────────────────────────────────────────

log ""
log "Rollback complete. Quick verification:"
log "  systemctl is-active docker"
log "  docker images                                          # should list ${ANSIBLE_IMAGE}"
log "  docker run --rm ${ANSIBLE_IMAGE} ansible --version     # smoke-test"
log ""
log "To restore the PXE container stack, re-run the Ansible playbook:"
log "  cd /root/bootstrap && ./bootstrap.sh"
log "  (or just the pxe_server tags if Docker is already up)"
