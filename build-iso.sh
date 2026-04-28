#!/bin/bash
# build-iso.sh — Build a custom Rocky Linux 9.7 Bootstrap + PXE Server ISO
#
# Prerequisites (internet-connected machine):
#   dnf install xorriso isomd5sum curl python3 rsync
#   Docker must be installed and running (for docker pull/save/build)
#
# Usage:
#   ./build-iso.sh
#
# The kickstart file (bootstrap.ks) must be in the same directory as this script.
# Output: bootstrap-pxe-<date>.iso in the current directory.
#
# Disk space: ~50 GB required in the working directory (more if including PXE client ISOs).

set -euo pipefail

# ── Configuration ─────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KS_FILE="${SCRIPT_DIR}/bootstrap.ks"

ROCKY_VERSION="9.7"
ROCKY_ARCH="x86_64"
ROCKY_ISO_URL="https://download.rockylinux.org/pub/rocky/9.7/isos/x86_64/Rocky-9.7-x86_64-dvd.iso"
ROCKY_ISO_SHA256=""  # Will be fetched from CHECKSUM file

DOCKER_CE_REPO="https://download.docker.com/linux/centos/9/x86_64/stable/Packages"
EPEL_REPO_URL="https://dl.fedoraproject.org/pub/epel/9/Everything/x86_64/Packages"
VSCODE_RPM_URL="https://update.code.visualstudio.com/latest/linux-rpm-x64/stable"

ANSIBLE_IMAGE="${ANSIBLE_RUNNER_IMAGE:-mma38e/ansible-runner:latest}"

# PXE client ISO URLs — override with environment variables if needed
UBUNTU_ISO_URL="${UBUNTU_ISO_URL:-https://releases.ubuntu.com/22.04/ubuntu-22.04.5-live-server-amd64.iso}"
UBUNTU_ISO_SHA256="${UBUNTU_ISO_SHA256:-9bc6028870aef3f74f4e16b900008179e78b130e6b0b9a140635434a46aa98b0}"
ROCKY_PXE_ISO_URL="${ROCKY_PXE_ISO_URL:-https://download.rockylinux.org/pub/rocky/9/isos/x86_64/Rocky-9.7-x86_64-dvd.iso}"
ROCKY_PXE_ISO_SHA256="${ROCKY_PXE_ISO_SHA256:-d48e902325dce6793935b4e13672a0d9a4f958e02d4e23fcf0a8a34c49ef03da}"

DATE_TAG="$(date +%Y%m%d)"
OUTPUT_ISO="${SCRIPT_DIR}/bootstrap-pxe-${DATE_TAG}.iso"

# Volume label for the output ISO. Must be FAT32-compatible (≤11 chars,
# A-Z 0-9 _) so Rufus preserves it on USB write. Used by the boot menu's
# inst.stage2=hd:LABEL=... and inst.repo=hd:LABEL=... so the same kickstart
# resolves whether booted from CD-ROM or from USB.
ISO_LABEL="BSTRAP_PXE"

WORK_DIR="${SCRIPT_DIR}/work"
ISO_WORK="${WORK_DIR}/iso"
FILES_DIR="${SCRIPT_DIR}/files"
RPM_DIR="${FILES_DIR}/rpms"
IMAGE_DIR="${FILES_DIR}/images"
PXE_ISO_DIR="${FILES_DIR}/isos"

# ── Helpers ───────────────────────────────────────────────────────────────────

log()  { echo "[build-iso] $*"; }
step() { echo ""; echo "[build-iso] ── $* ──────────────────────────────────────────"; }
die()  { echo "[build-iso] ERROR: $*" >&2; exit 1; }

# ── Preflight: tool check ─────────────────────────────────────────────────────

step "Checking required tools"

REQUIRED_TOOLS=(xorriso implantisomd5 curl openssl python3 docker rsync)
MISSING=()
for tool in "${REQUIRED_TOOLS[@]}"; do
    if ! command -v "${tool}" &>/dev/null; then
        MISSING+=("${tool}")
    fi
done

if [[ ${#MISSING[@]} -gt 0 ]]; then
    die "Missing required tools: ${MISSING[*]}
  Install with: dnf install xorriso isomd5sum curl python3 rsync
  Docker must be installed separately."
fi

[[ -f "${KS_FILE}" ]] || die "Kickstart not found: ${KS_FILE}"

log "All required tools present"

# ── Preflight: disk space ─────────────────────────────────────────────────────

step "Checking disk space"

REQUIRED_GB=40
AVAIL_GB=$(df -BG "${SCRIPT_DIR}" | awk 'NR==2 {gsub(/G/,"",$4); print $4}')

log "Available: ${AVAIL_GB} GB   Required: ${REQUIRED_GB} GB"

if [[ "${AVAIL_GB}" -lt "${REQUIRED_GB}" ]]; then
    die "Insufficient disk space: ${AVAIL_GB} GB available, ${REQUIRED_GB} GB required.
  Free up space in: ${SCRIPT_DIR}"
fi

log "Disk space OK"

# ── Gather all inputs ─────────────────────────────────────────────────────────
# All interactive prompts are collected here before any downloads begin.

step "Configuration"

# Root password
echo "Enter the root password for the bootstrap server."
echo "This will be hashed with SHA-512 and embedded in the kickstart."
echo ""

while true; do
    read -rsp "Root password: " ROOT_PASS
    echo ""
    read -rsp "Confirm password: " ROOT_PASS2
    echo ""
    [[ "${ROOT_PASS}" == "${ROOT_PASS2}" ]] && break
    echo "Passwords do not match. Try again."
done

[[ -n "${ROOT_PASS}" ]] || die "Password cannot be empty"

log "Generating SHA-512 password hash..."
ROOT_PW_HASH=$(openssl passwd -6 "${ROOT_PASS}")
ROOT_PASS=""
ROOT_PASS2=""
log "Password hash generated"

echo ""

# ansible-runner image
echo "ansible-runner image to embed [${ANSIBLE_IMAGE}]: "
read -rp "> " INPUT_IMAGE
[[ -n "${INPUT_IMAGE}" ]] && ANSIBLE_IMAGE="${INPUT_IMAGE}"
log "Using image: ${ANSIBLE_IMAGE}"

echo ""

# PXE client ISOs
echo "Download PXE client ISOs? (served to machines that network-boot from this server)"
echo "  - Ubuntu 22.04 Live Server  (~2 GB)"
echo "  - Rocky Linux 9 DVD         (~10 GB)"
echo ""
echo "  Note: ISOs are NOT embedded in the bootstrap ISO (too large for ISO 9660)."
echo "  They are downloaded alongside it and must be transferred to the airgap"
echo "  machine separately. See the transfer checklist printed at the end."
echo ""
read -rp "Download PXE client ISOs? [y/N] " INCLUDE_PXE_ISOS

log "Inputs collected — starting build"

# ── Download: Rocky ISO ───────────────────────────────────────────────────────

step "Rocky Linux ${ROCKY_VERSION} ISO"

ROCKY_ISO="${WORK_DIR}/rocky-${ROCKY_VERSION}.iso"
mkdir -p "${WORK_DIR}"

if [[ -f "${ROCKY_ISO}" ]]; then
    log "ISO already downloaded — verifying checksum..."
else
    log "Downloading ${ROCKY_ISO_URL}..."
    curl -L --progress-bar --retry 3 -o "${ROCKY_ISO}" "${ROCKY_ISO_URL}"
fi

# Fetch official checksum if not hardcoded
if [[ -z "${ROCKY_ISO_SHA256}" ]]; then
    log "Fetching official CHECKSUM from Rocky Linux..."
    # Always match the canonical DVD filename, even if downloading from a mirror/proxy
    ISO_FILENAME="Rocky-${ROCKY_VERSION}-${ROCKY_ARCH}-dvd.iso"
    CHECKSUM_URL="https://download.rockylinux.org/pub/rocky/${ROCKY_VERSION}/isos/${ROCKY_ARCH}/CHECKSUM"
    ROCKY_ISO_SHA256=$(curl -sL "${CHECKSUM_URL}" | grep "SHA256.*${ISO_FILENAME}" | grep -oE '[a-f0-9]{64}' | head -1)
    if [[ -z "${ROCKY_ISO_SHA256}" ]]; then
        log "WARNING: Could not fetch official checksum. Skipping verification."
    fi
fi

if [[ -n "${ROCKY_ISO_SHA256}" ]]; then
    log "Verifying ISO checksum..."
    ACTUAL_SHA=$(sha256sum "${ROCKY_ISO}" | awk '{print $1}')
    if [[ "${ACTUAL_SHA}" != "${ROCKY_ISO_SHA256}" ]]; then
        die "SHA-256 mismatch!
  Expected: ${ROCKY_ISO_SHA256}
  Got:      ${ACTUAL_SHA}
  Delete ${ROCKY_ISO} and retry."
    fi
    log "ISO checksum verified"
else
    log "Skipping checksum verification (no reference hash available)"
fi

# ── Download: Docker CE RPMs ──────────────────────────────────────────────────

step "Docker CE RPMs"

mkdir -p "${RPM_DIR}/docker" "${RPM_DIR}/epel"

log "Fetching Docker CE package list..."
DOCKER_PKG_HTML=$(curl -sL "${DOCKER_CE_REPO}/")
DOCKER_PKGS=(
    "docker-ce"
    "docker-ce-cli"
    "containerd.io"
    "docker-compose-plugin"
)

for PKG in "${DOCKER_PKGS[@]}"; do
    # Get the latest RPM filename for this package
    LATEST_RPM=$(echo "${DOCKER_PKG_HTML}" \
        | grep -oE "\"${PKG}-[0-9][^\"]*\.x86_64\.rpm\"" \
        | tr -d '"' | sort -V | tail -1)

    if [[ -z "${LATEST_RPM}" ]]; then
        die "Could not find latest RPM for: ${PKG}"
    fi

    DEST="${RPM_DIR}/docker/${LATEST_RPM}"
    if [[ -f "${DEST}" ]]; then
        log "  Already downloaded: ${LATEST_RPM}"
    else
        log "  Downloading: ${LATEST_RPM}"
        curl -L --progress-bar --retry 3 \
            -o "${DEST}" \
            "${DOCKER_CE_REPO}/${LATEST_RPM}"
    fi
done

log "Docker CE RPMs ready"

# ── Download: EPEL packages ──────────────────────────────────────────────────

step "EPEL packages (htop, iotop, iperf3, minicom, screen, filesystem tools + deps)"

# Download EPEL RPMs using dnf on the build machine.
# This resolves all dependencies automatically.
EPEL_PKGS=(htop iotop iperf3 minicom screen ntfs-3g ntfsprogs exfatprogs dosfstools fuse3)

log "Downloading EPEL packages and dependencies..."
dnf download --resolve --destdir="${RPM_DIR}/epel" \
    --repo=epel --repo=baseos --repo=appstream \
    "${EPEL_PKGS[@]}" 2>&1 | tail -5

log "EPEL packages ready: $(ls "${RPM_DIR}"/epel/*.rpm 2>/dev/null | wc -l) RPMs"

# ── Download: VS Code RPM ────────────────────────────────────────────────────

step "VS Code RPM"

mkdir -p "${RPM_DIR}/vscode"
VSCODE_DEST="${RPM_DIR}/vscode/code-latest.x86_64.rpm"

if [[ -f "${VSCODE_DEST}" ]]; then
    log "VS Code RPM already downloaded"
else
    log "Downloading VS Code RPM..."
    curl -L --progress-bar --retry 3 -o "${VSCODE_DEST}" "${VSCODE_RPM_URL}"
fi

log "VS Code RPM ready: $(du -sh "${VSCODE_DEST}" | cut -f1)"

# ── Pull & save ansible-runner image ─────────────────────────────────────────

step "ansible-runner container image"

mkdir -p "${IMAGE_DIR}"
IMAGE_TAR="${IMAGE_DIR}/ansible-runner.tar"

if [[ -f "${IMAGE_TAR}" ]]; then
    log "Image tarball already exists — skipping pull (delete ${IMAGE_TAR} to force re-pull)"
else
    log "Pulling ${ANSIBLE_IMAGE}..."
    docker pull "${ANSIBLE_IMAGE}"

    log "Saving to ${IMAGE_TAR}..."
    docker save "${ANSIBLE_IMAGE}" > "${IMAGE_TAR}"

    IMAGE_SIZE=$(du -sh "${IMAGE_TAR}" | cut -f1)
    log "Image saved: ${IMAGE_SIZE}"
fi

# ── Build & save PXE container images ────────────────────────────────────────

step "PXE container images"

PXE_TAR="${IMAGE_DIR}/pxe-images.tar"

if [[ -f "${PXE_TAR}" ]]; then
    log "PXE images tarball already exists — skipping build (delete ${PXE_TAR} to force rebuild)"
else
    log "Building PXE containers (docker compose build)..."
    (cd "${SCRIPT_DIR}" && docker compose build 2>&1 | tail -5)

    log "Saving pxe-dhcp:local pxe-tftp:local pxe-http:local..."
    docker save pxe-dhcp:local pxe-tftp:local pxe-http:local -o "${PXE_TAR}"

    PXE_TAR_SIZE=$(du -sh "${PXE_TAR}" | cut -f1)
    log "PXE images saved: ${PXE_TAR_SIZE}"
fi

# ── Download PXE client ISOs (optional) ──────────────────────────────────────

step "PXE client ISOs"

if [[ "${INCLUDE_PXE_ISOS,,}" == "y" ]]; then
    mkdir -p "${PXE_ISO_DIR}"

    # Ubuntu 22.04
    UBUNTU_DEST="${PXE_ISO_DIR}/ubuntu-22.04-live-server-amd64.iso"
    if [[ -f "${UBUNTU_DEST}" ]]; then
        log "Ubuntu ISO already downloaded"
    else
        log "Downloading Ubuntu 22.04 Live Server ISO..."
        curl -L --progress-bar --retry 3 -o "${UBUNTU_DEST}" "${UBUNTU_ISO_URL}"
    fi
    log "Verifying Ubuntu ISO checksum..."
    ACTUAL_SHA=$(sha256sum "${UBUNTU_DEST}" | awk '{print $1}')
    if [[ "${ACTUAL_SHA}" != "${UBUNTU_ISO_SHA256}" ]]; then
        die "Ubuntu ISO checksum mismatch!
  Expected: ${UBUNTU_ISO_SHA256}
  Got:      ${ACTUAL_SHA}"
    fi
    log "Ubuntu ISO verified"

    # Rocky Linux 9
    ROCKY_PXE_DEST="${PXE_ISO_DIR}/Rocky-9-dvd.iso"
    if [[ -f "${ROCKY_PXE_DEST}" ]]; then
        log "Rocky PXE client ISO already downloaded"
    else
        log "Downloading Rocky Linux 9 DVD ISO..."
        curl -L --progress-bar --retry 3 -o "${ROCKY_PXE_DEST}" "${ROCKY_PXE_ISO_URL}"
    fi
    log "Verifying Rocky ISO checksum..."
    ACTUAL_SHA=$(sha256sum "${ROCKY_PXE_DEST}" | awk '{print $1}')
    if [[ "${ACTUAL_SHA}" != "${ROCKY_PXE_ISO_SHA256}" ]]; then
        die "Rocky PXE ISO checksum mismatch!
  Expected: ${ROCKY_PXE_ISO_SHA256}
  Got:      ${ACTUAL_SHA}"
    fi
    log "Rocky PXE ISO verified"

    log "PXE client ISOs ready"
else
    log "Skipping PXE client ISOs — see transfer checklist at end of build"
fi

# ── Extract Rocky ISO ─────────────────────────────────────────────────────────

step "Extracting Rocky ISO"

[[ -d "${ISO_WORK}" ]] && rm -rf "${ISO_WORK}"
mkdir -p "${ISO_WORK}"

log "Extracting ISO contents (this may take a minute)..."
xorriso -osirrox on \
    -indev "${ROCKY_ISO}" \
    -extract / "${ISO_WORK}/" \
    2>/dev/null

# Make writable (xorriso extracts read-only)
chmod -R u+w "${ISO_WORK}/"

log "ISO extracted to ${ISO_WORK}/"

# ── Inject bootstrap artifacts ────────────────────────────────────────────────

step "Injecting bootstrap artifacts"

# Inject kickstart with password hash + baseline version/date substituted.
# VERSION is the single source of truth for the baseline release; bumped
# (along with a CHANGELOG entry) at PR-merge time per AGENTS.md rule #1.
VERSION_FILE="${SCRIPT_DIR}/VERSION"
[[ -f "${VERSION_FILE}" ]] || die "VERSION file not found: ${VERSION_FILE}"
BASELINE_VERSION=$(tr -d '[:space:]' < "${VERSION_FILE}")
BASELINE_BUILD_DATE=$(date -u +%Y-%m-%d)
[[ -n "${BASELINE_VERSION}" ]] || die "VERSION file is empty"

log "Processing kickstart file (baseline ${BASELINE_VERSION}, built ${BASELINE_BUILD_DATE})..."
KS_INJECTED="${ISO_WORK}/bootstrap.ks"
sed -e "s|__ROOT_PW_HASH__|${ROOT_PW_HASH}|g" \
    -e "s|__BASELINE_VERSION__|${BASELINE_VERSION}|g" \
    -e "s|__BASELINE_BUILD_DATE__|${BASELINE_BUILD_DATE}|g" \
    "${KS_FILE}" > "${KS_INJECTED}"

# Inject bootstrap.sh
log "Copying bootstrap.sh..."
cp "${SCRIPT_DIR}/bootstrap.sh" "${ISO_WORK}/bootstrap.sh"
chmod +x "${ISO_WORK}/bootstrap.sh"

# Inject Ansible directory
if [[ -d "${SCRIPT_DIR}/ansible" ]]; then
    log "Copying ansible/..."
    cp -r "${SCRIPT_DIR}/ansible" "${ISO_WORK}/ansible"
fi

# Inject files (RPMs + images — PXE client ISOs are NOT embedded; too large for ISO 9660)
log "Copying files/ (RPMs + images — this may take several minutes)..."
rsync -a --exclude='isos/' "${FILES_DIR}/" "${ISO_WORK}/files/"

# Inject PXE containers and docker-compose
log "Copying containers/ and docker-compose.yml..."
cp -r "${SCRIPT_DIR}/containers" "${ISO_WORK}/containers"
cp "${SCRIPT_DIR}/docker-compose.yml" "${ISO_WORK}/docker-compose.yml"

log "Artifacts injected"

# ── Update boot menus ─────────────────────────────────────────────────────────

step "Updating boot menus"

# ── isolinux (BIOS) ──────────────────────────────────────────────────────────
ISOLINUX_CFG="${ISO_WORK}/isolinux/isolinux.cfg"
if [[ -f "${ISOLINUX_CFG}" ]]; then
    log "Patching isolinux/isolinux.cfg..."
    # Prepend our two entries (CD-ROM default + USB) and set default timeout.
    # The same kickstart serves both — only inst.repo= and inst.ks= differ.
    ISOLINUX_ENTRY=$(cat <<ISOL

label bootstrap-cd
  menu label ^Bootstrap Install (CD-ROM)
  menu default
  kernel vmlinuz
  append initrd=initrd.img inst.stage2=hd:LABEL=${ISO_LABEL} inst.repo=cdrom inst.ks=cdrom:/bootstrap.ks quiet

label bootstrap-usb
  menu label Bootstrap Install (^USB)
  kernel vmlinuz
  append initrd=initrd.img inst.stage2=hd:LABEL=${ISO_LABEL} inst.repo=hd:LABEL=${ISO_LABEL} inst.ks=hd:LABEL=${ISO_LABEL}:/bootstrap.ks quiet

ISOL
)
    # Insert after the first 'menu' line
    python3 - "${ISOLINUX_CFG}" "${ISOLINUX_ENTRY}" <<'PYEOF'
import sys, pathlib

cfg_path = pathlib.Path(sys.argv[1])
new_entry = sys.argv[2]

lines = cfg_path.read_text().splitlines(keepends=True)
output = []
inserted = False
for line in lines:
    output.append(line)
    # Insert after the line that sets the menu title / begin block
    if not inserted and line.strip().startswith('menu title'):
        output.append(new_entry)
        inserted = True

if not inserted:
    output.insert(0, new_entry)

# Set timeout to 100 (10 seconds in isolinux units)
result = ''.join(output)
import re
result = re.sub(r'^timeout\s+\d+', 'timeout 100', result, flags=re.MULTILINE)
cfg_path.write_text(result)
PYEOF
fi

# ── GRUB2 (EFI) ──────────────────────────────────────────────────────────────
GRUB_CFG="${ISO_WORK}/EFI/BOOT/grub.cfg"
if [[ ! -f "${GRUB_CFG}" ]]; then
    GRUB_CFG="${ISO_WORK}/EFI/BOOT/BOOT.conf"
fi

if [[ -f "${GRUB_CFG}" ]]; then
    log "Patching EFI/BOOT/grub.cfg..."
    GRUB_ENTRY=$(cat <<GRUB

menuentry 'Bootstrap Install (CD-ROM)' --class fedora --class gnu-linux --class gnu --class os {
    linuxefi /images/pxeboot/vmlinuz inst.stage2=hd:LABEL=${ISO_LABEL} inst.repo=cdrom inst.ks=cdrom:/bootstrap.ks quiet
    initrdefi /images/pxeboot/initrd.img
}

menuentry 'Bootstrap Install (USB)' --class fedora --class gnu-linux --class gnu --class os {
    linuxefi /images/pxeboot/vmlinuz inst.stage2=hd:LABEL=${ISO_LABEL} inst.repo=hd:LABEL=${ISO_LABEL} inst.ks=hd:LABEL=${ISO_LABEL}:/bootstrap.ks quiet
    initrdefi /images/pxeboot/initrd.img
}

GRUB
)
    python3 - "${GRUB_CFG}" "${GRUB_ENTRY}" <<'PYEOF'
import sys, pathlib, re

cfg_path = pathlib.Path(sys.argv[1])
new_entry = sys.argv[2]

content = cfg_path.read_text()

# Set default to 0 (our new entry, prepended) and timeout to 10s
content = re.sub(r'set default="\d+"', 'set default="0"', content)
content = re.sub(r'set timeout=\d+', 'set timeout=10', content)

# Prepend entry before the first menuentry block, ensuring a blank line separator
entry = new_entry.rstrip('\n') + '\n\n'
content = re.sub(r'(menuentry\s)', entry + r'\1', content, count=1)

cfg_path.write_text(content)
PYEOF
fi

log "Boot menus updated"

# ── Repackage ISO ─────────────────────────────────────────────────────────────

step "Repackaging ISO"

# Use our own short, FAT32-compatible label (ISO_LABEL) instead of Rocky's
# 20-char "Rocky-9-7-x86_64-dvd" — Rufus would otherwise truncate or rewrite
# it on USB write, breaking the boot menu's hd:LABEL=... lookups.
log "Volume label: ${ISO_LABEL}"

log "Building new ISO..."
xorriso -as mkisofs \
    -o "${OUTPUT_ISO}" \
    -V "${ISO_LABEL}" \
    -J -joliet-long -r \
    -b isolinux/isolinux.bin \
    -c isolinux/boot.cat \
    -boot-load-size 4 \
    -boot-info-table \
    -no-emul-boot \
    -eltorito-alt-boot \
    -e images/efiboot.img \
    -no-emul-boot \
    -isohybrid-gpt-basdat \
    "${ISO_WORK}/" \
    2>&1 | grep -v "^xorriso" | grep -v "^$" || true

# ── Implant MD5 ───────────────────────────────────────────────────────────────

log "Implanting ISO MD5..."
implantisomd5 "${OUTPUT_ISO}"

# ── Final report ──────────────────────────────────────────────────────────────

step "Complete"

ISO_SIZE=$(du -sh "${OUTPUT_ISO}" | cut -f1)
ISO_SHA=$(sha256sum "${OUTPUT_ISO}" | awk '{print $1}')

echo ""
echo "=========================================="
echo "  Bootstrap + PXE Server ISO ready"
echo "=========================================="
echo "  File:   ${OUTPUT_ISO}"
echo "  Size:   ${ISO_SIZE}"
echo "  SHA256: ${ISO_SHA}"
echo ""
echo "  ── Airgap Transfer Checklist ──────────"
echo ""
echo "  [1] Bootstrap ISO  (write to USB or burn to disc)"
echo "      ${OUTPUT_ISO}"
echo ""
echo "  [2] PXE client ISOs  (copy to a separate USB drive or"
echo "      alongside the bootstrap ISO if space allows)"
if [[ -d "${PXE_ISO_DIR}" ]] && compgen -G "${PXE_ISO_DIR}/*.iso" > /dev/null 2>&1; then
    for f in "${PXE_ISO_DIR}"/*.iso; do
        echo "      ${f}  ($(du -sh "${f}" | cut -f1))"
    done
    echo ""
    echo "      On the target machine after install, place these at:"
    echo "        /root/bootstrap/files/isos/"
    echo "      then run: ./bootstrap.sh"
else
    echo "      (none downloaded — PXE client ISOs were skipped)"
    echo "      To add them later, re-run build-iso.sh and answer [y]"
    echo "      to the PXE client ISO prompt, then transfer the files"
    echo "      in ${PXE_ISO_DIR}/ to /root/bootstrap/files/isos/"
    echo "      on the target machine before running bootstrap.sh"
fi
echo ""
echo "  ── First-boot steps ───────────────────"
echo "  1. Boot the target machine from the ISO"
echo "  2. Kickstart runs automatically — no interaction needed"
echo "  3. After reboot:"
echo "       cd /root/bootstrap && ./bootstrap.sh"
echo "=========================================="
