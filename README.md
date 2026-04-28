# bootstrap-pxe

A self-contained provisioning kit for a Rocky Linux 9.7 bootstrap + PXE server.

This is the **first machine** in an airgapped environment. It installs Rocky Linux,
configures itself as an infrastructure controller with Docker and Ansible, then runs
a containerized PXE server to network-boot all other machines. Everything from OS
install through PXE service deployment is handled by a single ISO.

---

## How It Works

```
[Internet machine]          [Target machine]
  build-iso.sh   ─→  ISO  ─→  kickstart  ─→  bootstrap.sh  ─→  Ansible roles
  (online prep)        (boot)   (OS install)   (Docker + load)   (bootstrap + PXE)
```

1. **`build-iso.sh`** runs on any internet-connected machine. It downloads the Rocky
   9.7 ISO, Docker CE RPMs, ansible-runner image, builds PXE container images, and
   optionally downloads PXE client ISOs (Ubuntu, Rocky). Everything is packed into
   a custom bootable ISO.

2. Boot the target machine from the ISO. **Anaconda** runs `bootstrap.ks`:
   - `%pre` prompts for hostname and static IP
   - Installs Rocky 9.7 with LVM
   - `%post` places all artifacts in `/root/bootstrap/`

3. After reboot, run **`bootstrap.sh`** as root:
   - Installs Docker CE from local RPMs (no internet needed)
   - Loads ansible-runner + PXE container images
   - Injects host IP into inventory and group_vars
   - Runs the Ansible playbook with both roles

4. **Ansible roles** finish the setup:
   - **`bootstrap_server`**: base packages, Docker service, admin user, directories
   - **`pxe_server`**: PXE boot files, configs, containerized DHCP/TFTP/HTTP stack

---

## Airgap Requirements

`build-iso.sh` downloads everything automatically on an internet-connected machine.
The resulting ISO is self-contained — no internet access is needed on the target.

| Artifact | Source | Notes |
|---|---|---|
| Rocky 9.7 DVD ISO | `download.rockylinux.org` | For installing the host OS |
| Docker CE RPMs | `download.docker.com` | docker-ce, cli, containerd, compose-plugin |
| EPEL packages | `dl.fedoraproject.org` | htop, iotop, iperf3, minicom, screen, ntfs-3g, ntfsprogs, exfatprogs, dosfstools, fuse3 + deps |
| ansible-runner image | `docker save mma38e/ansible-runner:latest` | Ansible execution container |
| PXE container images | Built by `docker compose build` | pxe-dhcp, pxe-tftp, pxe-http |
| Ubuntu 22.04 ISO | `releases.ubuntu.com` | Optional — for PXE clients |
| Rocky 9 DVD ISO | `download.rockylinux.org` | Optional — for PXE clients |

> The `files/` directory is gitignored. Never commit RPMs, images, or ISOs.

---

## Prerequisites

### On the internet-connected machine (for `build.sh`)

Only **Docker** is required on the host — `build.sh` runs the build inside a
containerized builder, so `xorriso`, `isomd5sum`, and the rest are installed
*inside* the container, not on the host.

Required disk space: **≥ 50 GB** (more if including PXE client ISOs).

### On the target machine

- Bootable media (USB, virtual ISO) containing the output ISO
- ≥ 80 GB disk, ≥ 8 GB RAM
- Console access for the kickstart network prompts

---

## Usage

### Step 1 — Build the ISO (internet-connected machine)

```bash
git clone <this-repo>
cd bootstrap-pxe
./build.sh
```

`build.sh` builds a local Rocky 9 + DinD builder image and runs `build-iso.sh`
inside it. Don't invoke `build-iso.sh` directly — it expects `xorriso`,
`implantisomd5`, and a Linux Docker stack on the host PATH, which is rarely the
case (especially on macOS). The builder's image cache persists in the named
Docker volume `bootstrap-pxe-builder-cache` so `ansible-runner` isn't re-pulled
on every run.

The script will prompt for:
- Root password (hashed with SHA-512, embedded in kickstart)
- ansible-runner image tag (default: `mma38e/ansible-runner:latest`)
- Whether to include PXE client ISOs (~12 GB extra)

Output: `bootstrap-pxe-<YYYYMMDD>.iso`

### Step 2 — Boot the target machine

Write the ISO to USB or mount as a virtual disk and boot. The boot menu offers
two install entries that point at the same kickstart:

- **Bootstrap Install (CD-ROM)** — default. Use when booting from physical
  optical media or a virtual ISO mount.
- **Bootstrap Install (USB)** — use when booting from a USB stick written by
  Rufus or `dd`. The install source is read from the USB partition by volume
  label (`BSTRAP_PXE`) instead of from a CD-ROM device.

> **Rufus tip:** when prompted, select **DD Image mode** (not ISO mode). DD
> mode preserves the volume label and hybrid ISO layout the boot menu relies
> on. ISO mode reformats to FAT32 and may rename the volume.

The installer will then prompt for hostname, IP address, netmask, gateway,
and DNS.

### Step 3 — Complete setup

```bash
cd /root/bootstrap
./bootstrap.sh
```

This installs Docker, loads all container images, and runs both Ansible roles.
On completion it prints next steps:

1. **Change the admin password** (default is `password`): `passwd cloud`
2. **Open Cockpit**: `https://<IP>:9090`
3. **Switch to GUI** (optional): `systemctl set-default graphical.target && reboot`

Log out and back in to see the dynamic login banner with current system state.

---

## Configuration

### Bootstrap server variables

Override in `ansible/group_vars/all.yml` or via `-e` flags:

| Variable | Default | What it installs / does |
|---|---|---|
| `bootstrap_admin_user` | `cloud` | Admin username created by Ansible |
| `bootstrap_admin_password` | `password` | Default password — **change in group_vars or vault** |
| `install_baseline` | `true` | Full baseline tool set — see `baseline_packages` in `bootstrap_server/defaults/main.yml`. Includes base utilities, dev/build, network, monitoring, serial, and filesystem tools (NTFS / exFAT / FAT32 / ext4 / XFS). |
| `install_cockpit` | `true` | Enable cockpit.socket + firewall port 9090 |
| `install_k8s_tools` | `false` | kubectl, helm, k9s |

### PXE server variables

| Variable | Default | Purpose |
|---|---|---|
| `airgap_mode` | `true` | Skip ISO downloads, use pre-staged files |
| `dhcp_interface` | `eth0` | Network interface for dnsmasq |
| `dhcp_enabled` | `false` | false=proxyDHCP, true=standalone DHCP |
| `ubuntu2204_enabled` | `true` | Enable Ubuntu PXE boot entries |
| `rocky9_enabled` | `true` | Enable Rocky PXE boot entries |

### Re-running Ansible only

Once Docker is installed, re-run just the playbook:

```bash
cd /root/bootstrap
docker run --rm -i \
    --network host \
    -v "$(pwd)/ansible:/runner" \
    -v /root/.ssh:/root/.ssh:ro \
    -w /runner \
    mma38e/ansible-runner:latest \
    ansible-playbook -i inventory.ini site.yml
```

Use `--tags packages`, `--tags pxe`, etc. to target specific stages.

---

## Repository Structure

```
bootstrap-pxe/
├── build.sh                  Top-level entry — builds the builder, runs build-iso.sh inside
├── build-iso.sh              Online ISO build script (runs inside the builder container)
├── Dockerfile                Builder image (Rocky 9 + DinD + xorriso + isomd5sum + docker)
├── docker-entrypoint.sh      Boots dockerd inside the builder, then execs build-iso.sh
├── bootstrap.ks              Rocky 9.7 kickstart (injected into ISO)
├── bootstrap.sh              Post-install (Docker + images + run Ansible)
├── docker-compose.yml        PXE container stack definition
├── containers/               PXE container Dockerfiles
│   ├── dhcp/                 alpine + dnsmasq
│   ├── tftp/                 alpine + tftpd-hpa (multi-stage build)
│   └── http/                 nginx:alpine
├── ansible/
│   ├── site.yml              Main playbook (both roles)
│   ├── inventory.ini
│   ├── group_vars/all.yml    Site-specific overrides
│   └── roles/
│       ├── bootstrap_server/ Host setup: packages, Docker, users, dirs
│       └── pxe_server/       PXE setup: boot files, configs, containers
├── files/                    Airgap artifacts — gitignored
├── AGENTS.md                 Architecture reference + developer rules
└── CHANGELOG.md              Change history
```

See `AGENTS.md` for full architecture details and developer rules.

---

## Future Work

- NVIDIA driver support
- Cockpit profile for baremetal deployments
- Full repo sync support
- Secure Boot support for PXE clients (ship `grub-efi-amd64-signed` grubnetx64.efi.signed chained through shim; requires signed downstream kernels)
- Google Chrome install (RPM bundled for airgap; pinned via group_vars toggle)
- DoD PKI certificates (install DoD root + intermediate CAs into system trust store, NSSDB for Chrome/Firefox)
- Classification banner (login/GDM + Cockpit header banner, configurable level via group_vars)
- LibreOffice support (RPM group bundled for airgap; toggle via group_vars)

---

## Contributing

All changes must include updates to:
1. **`CHANGELOG.md`** — add an entry under today's version/date
2. **`AGENTS.md`** — update architecture or rules sections if applicable

See `AGENTS.md` for full developer rules.
