#version=RHEL9
# Rocky Linux 9.7 Kickstart — Bootstrap Server
# This file is injected into the ISO by build-iso.sh.
# Do not edit the copy inside the ISO directly; edit this source file and rebuild.

cdrom
text
reboot

lang en_US.UTF-8
keyboard --vckeymap=us --xlayouts=us
timezone UTC --isUtc

# ── Network (static IP collected in %pre) ────────────────────────────────────
%include /tmp/network.ks

# ── Authentication ────────────────────────────────────────────────────────────
# Root password hash injected by build-iso.sh (token: __ROOT_PW_HASH__)
rootpw --iscrypted __ROOT_PW_HASH__

selinux --enforcing
firewall --enabled --service=ssh

# ── Disk ──────────────────────────────────────────────────────────────────────
zerombr
clearpart --all --initlabel
part /boot      --fstype=xfs  --size=1024
part /boot/efi  --fstype=efi  --size=512
part pv.01      --grow        --size=1

volgroup vg_bootstrap pv.01

logvol swap           --vgname=vg_bootstrap --fstype=swap --size=4096   --name=lv_swap
logvol /              --vgname=vg_bootstrap --fstype=ext4 --size=1      --name=lv_root --grow

bootloader --location=mbr

# ── Packages ──────────────────────────────────────────────────────────────────
%packages
@^graphical-server-environment
@virtualization-hypervisor
@virtualization-tools
@debugging
@network-file-system-client
@remote-desktop-clients
@remote-system-management
@smart-card
@security-tools
@system-tools
@virtualization-client
@virtualization-platform
openscap
openscap-utils
cockpit-machines
openssh-server
python3
%end

# ── Pre-install: collect network settings ────────────────────────────────────
%pre --interpreter=/usr/bin/bash
exec < /dev/tty6 > /dev/tty6 2> /dev/tty6
chvt 6

clear
echo "=========================================="
echo "  Bootstrap Server — Network Configuration"
echo "=========================================="
echo ""

# Hostname
HOSTSHORT=""
while [ -z "$HOSTSHORT" ]; do
    read -p "Hostname (e.g. bootstrap01): " HOSTSHORT
done

# IP address
IP=""
while [ -z "$IP" ]; do
    read -p "IP address (e.g. 192.168.1.10): " IP
done

# Default netmask and gateway
NETMASK=255.255.255.0
SUBNET=$(echo $IP | awk -F. '{print $1 "." $2 "." $3}')
GATEWAY="${SUBNET}.1"

echo ""
echo "Current defaults:  Netmask: ${NETMASK}  Gateway: ${GATEWAY}"
read -p "Change defaults? (y/N): " REPLY
if [ "$REPLY" = "y" ] || [ "$REPLY" = "Y" ]; then
    echo ""
    echo "Enter netmask or CIDR prefix (e.g. 255.255.255.0 or /24)"
    read -p "Netmask [${NETMASK}]: " NEW_MASK
    if [ -n "$NEW_MASK" ]; then
        NETMASK="$NEW_MASK"
    fi

    read -p "Gateway [${GATEWAY}]: " NEW_GW
    if [ -n "$NEW_GW" ]; then
        GATEWAY="$NEW_GW"
    fi
fi

# Convert CIDR prefix to subnet mask if needed
if [ "${NETMASK:0:1}" = "/" ]; then
    PREFIX="${NETMASK:1}"
    NETMASK=$(ipcalc -m ${IP}/${PREFIX} | sed 's/.*=//')
fi

# DNS
DNS1=""
while [ -z "$DNS1" ]; do
    read -p "Primary DNS: " DNS1
done
read -p "Secondary DNS (leave blank to skip): " DNS2

DNS_CLAUSE="--nameserver=$DNS1"
if [ -n "$DNS2" ]; then
    DNS_CLAUSE="$DNS_CLAUSE --nameserver=$DNS2"
fi

# Determine the first ethernet interface name
IFACE=$(ip -o link show | awk -F': ' '!/lo:/{print $2; exit}')
IFACE="${IFACE:-link}"

echo ""
echo "Network config: ${IP} / ${NETMASK} via ${GATEWAY} on ${IFACE}"
echo ""
sleep 2

echo "network --bootproto=static --device=${IFACE} --noipv6 --hostname=${HOSTSHORT} --gateway=${GATEWAY} --ip=${IP} --netmask=${NETMASK} --onboot=yes --activate ${DNS_CLAUSE}" > /tmp/network.ks

chvt 1
exec < /dev/tty1 > /dev/tty1 2> /dev/tty1
%end

# ── Post-install: place bootstrap artifacts ───────────────────────────────────
%post --nochroot --log=/mnt/sysimage/root/ks-post.log
#!/bin/bash
set -euo pipefail

chroot /mnt/sysimage systemctl enable sshd

# Allow root SSH login (needed for ansible-runner to reach the host)
mkdir -p /mnt/sysimage/etc/ssh/sshd_config.d
echo "PermitRootLogin yes" > /mnt/sysimage/etc/ssh/sshd_config.d/01-permitrootlogin.conf

# --nochroot required to access the ISO mount point.
# Copy everything bootstrap.sh needs into the installed system.
ISO_ROOT="/run/install/repo"
DEST="/mnt/sysimage/root/bootstrap"
mkdir -p "${DEST}"

for item in bootstrap.sh ansible files containers docker-compose.yml; do
    if [[ -e "${ISO_ROOT}/${item}" ]]; then
        cp -r "${ISO_ROOT}/${item}" "${DEST}/"
    fi
done

chmod +x "${DEST}/bootstrap.sh" 2>/dev/null || true

cat > /mnt/sysimage/etc/motd <<'MOTD'
===========================================================
  Rocky Linux 9.7 — Bootstrap + PXE Server
===========================================================
  Run the following to complete setup:

    cd /root/bootstrap && ./bootstrap.sh

  This will install Docker CE, load container images,
  and run the Ansible playbooks that configure this
  machine as a bootstrap server and PXE boot server.
===========================================================
MOTD

echo "Kickstart post-install complete. Artifacts placed in ${DEST}/" >> /mnt/sysimage/root/ks-post.log
%end
