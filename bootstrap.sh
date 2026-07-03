#!/bin/bash
# bootstrap.sh — Phase 1 setup for the Bootstrap + PXE Server
#
# Run as root after the kickstart install completes:
#   cd /root/bootstrap && ./bootstrap.sh
#
# What this does:
#   0. Disables internet repos and mounts local ISO media
#   1. Installs Docker CE from local RPMs (airgap-safe)
#   2. Loads the ansible-runner container image
#   3. Loads the PXE container images (pxe-dhcp, pxe-tftp, pxe-http)
#   4. Stages PXE client ISOs (if present)
#   5. Injects host IP into Ansible inventory
#   6. Runs the Ansible playbook (bootstrap_server + pxe_server roles)
#
# All further machine configuration happens inside the Ansible roles.
# This script is intentionally minimal — its only job is to break the
# chicken/egg problem by getting Docker running and images loaded.

set -euo pipefail

# ── Config ────────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RPM_DIR="${SCRIPT_DIR}/files/rpms"
IMAGE_DIR="${SCRIPT_DIR}/files/images"
ANSIBLE_DIR="${SCRIPT_DIR}/ansible"
IMAGE_TAR="${IMAGE_DIR}/ansible-runner.tar"
PXE_IMAGE_TAR="${IMAGE_DIR}/pxe-images.tar"
PXE_ISO_DIR="${SCRIPT_DIR}/files/isos"
ANSIBLE_IMAGE="mma38e/ansible-runner:latest"
INVENTORY="inventory.ini"
PLAYBOOK="site.yml"

# ── Helpers ───────────────────────────────────────────────────────────────────

log()  { echo "[bootstrap] $*"; }
die()  { echo "[bootstrap] ERROR: $*" >&2; exit 1; }

# ── Preflight checks ──────────────────────────────────────────────────────────

[[ "$(id -u)" -eq 0 ]] || die "Must be run as root"

# Verify Rocky Linux 9
if ! grep -qi "rocky" /etc/os-release 2>/dev/null; then
    die "This script targets Rocky Linux 9.x only"
fi
OS_VERSION=$(grep "^VERSION_ID=" /etc/os-release | cut -d'"' -f2)
[[ "${OS_VERSION}" == 9* ]] || die "Requires Rocky Linux 9.x (found ${OS_VERSION})"

log "Running on Rocky Linux ${OS_VERSION}"

# Verify required directories
[[ -d "${RPM_DIR}" ]]    || die "RPM directory not found: ${RPM_DIR}"
[[ -f "${IMAGE_TAR}" ]]  || die "ansible-runner image not found: ${IMAGE_TAR}"
[[ -d "${ANSIBLE_DIR}" ]] || die "Ansible directory not found: ${ANSIBLE_DIR}"

# ── Step 0: Configure local media as dnf repo ────────────────────────────────

log "Disabling default internet repos..."
dnf config-manager --set-disabled '*' 2>/dev/null || true

# Mount the ISO if not already mounted
ISO_MOUNT="/mnt/iso"
if ! mountpoint -q "${ISO_MOUNT}" 2>/dev/null; then
    mkdir -p "${ISO_MOUNT}"
    # blkid exits 2 when nothing matches — without || true, set -e kills the
    # script here instead of reaching the "could not mount ISO" warning below.
    ISO_DEVICE=$(blkid -t TYPE=iso9660 -o device 2>/dev/null | head -1 || true)
    if [[ -n "${ISO_DEVICE}" ]]; then
        log "Mounting ISO from ${ISO_DEVICE}..."
        mount -o ro "${ISO_DEVICE}" "${ISO_MOUNT}"
    elif [[ -f /dev/cdrom ]]; then
        log "Mounting /dev/cdrom..."
        mount -o ro /dev/cdrom "${ISO_MOUNT}"
    fi
fi

# Create local repo files for BaseOS and AppStream from the mounted ISO
if mountpoint -q "${ISO_MOUNT}" 2>/dev/null; then
    log "Configuring local BaseOS repo..."
    cat > /etc/yum.repos.d/local-baseos.repo <<EOF
[local-baseos]
name=Rocky Linux 9 - BaseOS (Local)
baseurl=file://${ISO_MOUNT}/BaseOS
enabled=1
gpgcheck=0
EOF

    cat > /etc/yum.repos.d/local-appstream.repo <<EOF
[local-appstream]
name=Rocky Linux 9 - AppStream (Local)
baseurl=file://${ISO_MOUNT}/AppStream
enabled=1
gpgcheck=0
EOF
else
    log "WARNING: Could not mount ISO — dnf may not have package sources"
fi

# ── Step 1: Install EPEL packages, VS Code, Docker CE ────────────────────────

# Install EPEL packages by NAME from a local dnf repo, not via
# `dnf localinstall *.rpm`. The directory also holds base-library deps that
# `dnf download --resolve` pulled at mirror versions (newer than the DVD's);
# force-installing every RPM put them all in one transaction, which aborted
# on version conflicts and silently skipped htop/screen/etc. Installing by
# name lets dnf take only what is needed and resolve base deps from the DVD
# repos. Keep this list in sync with EPEL_PKGS in build-iso.sh.
EPEL_PKGS=(htop iotop iperf3 minicom screen ntfs-3g ntfsprogs exfatprogs dosfstools fuse3)

[[ -d "${RPM_DIR}/epel/repodata" ]] || die \
    "No repodata in ${RPM_DIR}/epel/ — this ISO was built by a pre-1.4.0 build-iso.sh. Rebuild the ISO."

log "Configuring local EPEL repo..."
cat > /etc/yum.repos.d/local-epel.repo <<EOF
[local-epel]
name=EPEL packages (Local)
baseurl=file://${RPM_DIR}/epel
enabled=1
gpgcheck=0
EOF

log "Installing EPEL packages from local-epel repo..."
dnf install -y "${EPEL_PKGS[@]}"

# Install VS Code from local RPM
VSCODE_RPMS=("${RPM_DIR}"/vscode/*.rpm)
if [[ -e "${VSCODE_RPMS[0]}" ]]; then
    log "Installing VS Code from local RPM..."
    dnf localinstall -y "${VSCODE_RPMS[@]}" || true
else
    log "WARNING: No VS Code RPM found in ${RPM_DIR}/vscode/"
fi

if systemctl is-active docker &>/dev/null; then
    log "Docker is already running — skipping install"
else
    log "Installing Docker CE from local RPMs..."
    DOCKER_RPMS=("${RPM_DIR}"/docker/*.rpm)
    [[ -e "${DOCKER_RPMS[0]}" ]] || die "No Docker RPMs found in ${RPM_DIR}/docker/"
    dnf localinstall -y "${DOCKER_RPMS[@]}"

    log "Enabling and starting Docker..."
    systemctl enable --now docker
fi

# ── Step 2: Load ansible-runner image ─────────────────────────────────────────

if docker image inspect "${ANSIBLE_IMAGE}" &>/dev/null; then
    log "ansible-runner image already loaded — skipping"
else
    log "Loading ansible-runner image from ${IMAGE_TAR}..."
    docker load < "${IMAGE_TAR}"
fi

# ── Step 3: Load PXE container images ────────────────────────────────────────

if [[ -f "${PXE_IMAGE_TAR}" ]]; then
    if docker image inspect pxe-dhcp:local &>/dev/null; then
        log "PXE container images already loaded — skipping"
    else
        log "Loading PXE container images from ${PXE_IMAGE_TAR}..."
        docker load < "${PXE_IMAGE_TAR}"
    fi
else
    log "WARNING: PXE images tarball not found: ${PXE_IMAGE_TAR}"
    log "PXE containers will need to be built by Ansible (requires internet)"
fi

# ── Step 4: Stage PXE client ISOs ────────────────────────────────────────────

if [[ -d "${PXE_ISO_DIR}" ]] && ls "${PXE_ISO_DIR}"/*.iso &>/dev/null; then
    log "PXE client ISOs found — they will be copied by Ansible during the pxe_server role"
else
    log "No PXE client ISOs found in ${PXE_ISO_DIR}/"
    log "ISOs can be added later and the playbook re-run"
fi

# ── Step 5: Inject host IP into inventory ────────────────────────────────────

# ansible-runner runs in a container, so it must target the host by IP (not localhost).
HOST_IP=$(hostname -I | awk '{print $1}')
[[ -n "${HOST_IP}" ]] || die "Could not determine host IP address"

log "Updating inventory with host IP: ${HOST_IP}"
sed -i "s|__BOOTSTRAP_IP__|${HOST_IP}|g" "${ANSIBLE_DIR}/${INVENTORY}"

# Also set pxe_server_ip to match host IP in group_vars
# (pxe_server role needs this to configure boot menus and DHCP)
if grep -q 'pxe_server_ip:' "${ANSIBLE_DIR}/group_vars/all.yml" 2>/dev/null; then
    log "pxe_server_ip already set in group_vars"
else
    log "Setting pxe_server_ip=${HOST_IP} in group_vars"
    echo "" >> "${ANSIBLE_DIR}/group_vars/all.yml"
    echo "# Auto-injected by bootstrap.sh" >> "${ANSIBLE_DIR}/group_vars/all.yml"
    echo "pxe_server_ip: \"${HOST_IP}\"" >> "${ANSIBLE_DIR}/group_vars/all.yml"
fi

# ── Step 6: Run Ansible playbook ─────────────────────────────────────────────

log "Running Ansible playbook (bootstrap_server + pxe_server roles)..."
# Mount the full bootstrap directory so pxe_server role can tar containers/ and
# docker-compose.yml when syncing project source to the target host.
# playbook_dir inside the container = /runner/ansible
docker run --rm -i \
    --network host \
    -v "${SCRIPT_DIR}:/runner" \
    -v /root/.ssh:/root/.ssh:ro \
    -w /runner/ansible \
    "${ANSIBLE_IMAGE}" \
    ansible-playbook -i "${INVENTORY}" "${PLAYBOOK}"

log "Bootstrap + PXE server setup complete."
log ""
log "Next steps:"
log "  1. Change the admin password (default is 'password'):"
log "       passwd cloud"
log ""
log "  2. Cockpit web console:"
log "       https://${HOST_IP}:9090"
log ""
log "  3. Switch to graphical target (optional, requires reboot):"
log "       systemctl set-default graphical.target && reboot"
log ""
log "  PXE clients can now network boot from this server."
log "  Log out and back in to see the post-setup quick reference."
