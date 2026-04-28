# ── Stage 1: extract boot binaries ───────────────────────────────────────────
# Use Ubuntu to install grub-efi and syslinux packages, then build a
# standalone grubx64.efi via grub-mkimage and collect all BIOS modules.
FROM ubuntu:22.04 AS boot-builder

RUN apt-get update && apt-get install -y --no-install-recommends \
        syslinux \
        syslinux-common \
        pxelinux \
        grub-efi-amd64-bin \
    && rm -rf /var/lib/apt/lists/*

# Ubuntu's pre-built GRUB EFI network boot binary (unsigned, monolithic).
RUN cp /usr/lib/grub/x86_64-efi/monolithic/grubnetx64.efi /grubx64.efi

# Collect BIOS syslinux files into one directory for easy COPY below
RUN mkdir /syslinux-bios && \
    cp /usr/lib/PXELINUX/pxelinux.0             /syslinux-bios/ && \
    cp /usr/lib/syslinux/modules/bios/ldlinux.c32  /syslinux-bios/ && \
    cp /usr/lib/syslinux/modules/bios/menu.c32     /syslinux-bios/ && \
    cp /usr/lib/syslinux/modules/bios/libutil.c32  /syslinux-bios/ && \
    cp /usr/lib/syslinux/modules/bios/libcom32.c32 /syslinux-bios/

# ── Stage 2: runtime TFTP server ─────────────────────────────────────────────
FROM alpine:3.19

RUN apk add --no-cache tftp-hpa

# Copy boot binaries from builder stage into a staging directory.
# entrypoint.sh copies these to /tftpboot (the bind-mount) on first start
# so Ansible does not need to source them separately.
COPY --from=boot-builder /grubx64.efi    /boot-files/grubx64.efi
COPY --from=boot-builder /syslinux-bios/ /boot-files/

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

VOLUME ["/tftpboot"]

ENTRYPOINT ["/entrypoint.sh"]
