#!/bin/sh
# dnsmasq entrypoint — generates /etc/dnsmasq.conf from environment variables
# at container start, then runs dnsmasq in the foreground.
#
# Environment variables (all set via docker-compose.yml / .env):
#   PXE_SERVER_IP    — IP of this server on the imaging network (required)
#   HTTP_SERVER_IP   — IP serving HTTP content (defaults to PXE_SERVER_IP)
#   DHCP_INTERFACE   — interface dnsmasq listens on (default: eth0)
#   DHCP_ENABLED     — "true" = full DHCP, anything else = proxyDHCP
#   DHCP_RANGE_START / DHCP_RANGE_END / DHCP_LEASE_TIME — used when DHCP_ENABLED=true
#   DHCP_GATEWAY / DHCP_DNS — used when DHCP_ENABLED=true

set -e

: "${PXE_SERVER_IP:?PXE_SERVER_IP must be set}"
HTTP_IP="${HTTP_SERVER_IP:-$PXE_SERVER_IP}"
IFACE="${DHCP_INTERFACE:-eth0}"

cat > /etc/dnsmasq.conf <<EOF
# dnsmasq PXE configuration
# Generated at container start from environment variables.
# To change settings, update .env and restart the container.

log-queries
log-dhcp
no-resolv
no-hosts

interface=${IFACE}
bind-interfaces

# dnsmasq's built-in TFTP is NOT used — the pxe-tftp container serves UDP/69.
# dhcp-boot lines below set the TFTP server address to ${PXE_SERVER_IP}.

# ── Architecture detection via DHCP option 93 (client-arch) ──────────────────
#
# IANA architecture types relevant here:
#   0x0000  Intel x86 (BIOS/legacy)   → pxelinux.0
#   0x0007  EFI x86-64 (BC_EFI)      → grubx64.efi
#   0x0009  EFI x86-64 (EFI_BC)      → grubx64.efi
#
# Tags are set on the incoming request and matched by the dhcp-boot lines below.
dhcp-match=set:bios,option:client-arch,0
dhcp-match=set:efi64,option:client-arch,7
dhcp-match=set:efi64,option:client-arch,9

# BIOS clients → syslinux/pxelinux
dhcp-boot=tag:bios,pxelinux.0,,${PXE_SERVER_IP}

# EFI x86-64 clients → GRUB2 EFI
dhcp-boot=tag:efi64,grubx64.efi,,${PXE_SERVER_IP}

# Fallback for unrecognised arch — attempt BIOS path
dhcp-boot=tag:!bios,tag:!efi64,pxelinux.0,,${PXE_SERVER_IP}

# PXE service entries (used by clients that support the PXE menu protocol)
pxe-service=tag:bios,x86PC,"PXE Boot Server",pxelinux.0,${PXE_SERVER_IP}
pxe-service=tag:efi64,BC_EFI,"PXE Boot Server (EFI)",grubx64.efi,${PXE_SERVER_IP}

EOF

# ── DHCP mode ─────────────────────────────────────────────────────────────────
if [ "${DHCP_ENABLED}" = "true" ]; then
    echo "# ── Full DHCP mode ──" >> /etc/dnsmasq.conf
    cat >> /etc/dnsmasq.conf <<EOF
dhcp-range=${DHCP_RANGE_START},${DHCP_RANGE_END},${DHCP_LEASE_TIME}
dhcp-option=3,${DHCP_GATEWAY}
dhcp-option=6,${DHCP_DNS}
EOF
    echo "[dhcp] Starting in full DHCP mode: ${DHCP_RANGE_START} - ${DHCP_RANGE_END}"
else
    echo "# ── proxyDHCP mode ──" >> /etc/dnsmasq.conf
    cat >> /etc/dnsmasq.conf <<EOF
# proxyDHCP: respond on port 4011 to clients that already have an IP from
# the network's DHCP server, injecting only the PXE boot filename.
dhcp-range=${PXE_SERVER_IP},proxy
EOF
    echo "[dhcp] Starting in proxyDHCP mode (router owns DHCP)"
fi

echo "[dhcp] PXE server IP: ${PXE_SERVER_IP}, HTTP server IP: ${HTTP_IP}, interface: ${IFACE}"

exec dnsmasq --no-daemon --log-facility=- "$@"
