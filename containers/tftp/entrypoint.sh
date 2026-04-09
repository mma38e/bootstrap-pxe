#!/bin/sh
# tftpd-hpa entrypoint
# 1. Copies boot binaries (grubx64.efi, pxelinux.0, syslinux modules) from
#    /boot-files/ (baked into the image) into /tftpboot (bind-mount) if they
#    are not already present. This means Ansible does not need to source them.
# 2. Starts tftpd-hpa serving /tftpboot over UDP/69.

set -e

TFTPROOT="/tftpboot"
BOOT_FILES="/boot-files"

if [ ! -d "${TFTPROOT}" ]; then
    echo "[tftp] ERROR: ${TFTPROOT} does not exist — bind mount not set up."
    exit 1
fi

# Copy boot binaries if not already present (idempotent)
for f in "${BOOT_FILES}"/*; do
    name="$(basename "${f}")"
    if [ ! -f "${TFTPROOT}/${name}" ]; then
        echo "[tftp] Installing boot file: ${name}"
        cp "${f}" "${TFTPROOT}/${name}"
    fi
done

echo "[tftp] Serving ${TFTPROOT} on UDP/69"

exec /usr/sbin/in.tftpd --listen --foreground --verbose --secure "${TFTPROOT}"
