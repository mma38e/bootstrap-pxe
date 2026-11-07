# bootstrap-pxe

A self-contained provisioning kit for Rocky Linux 9.8. One ISO installs either of
two profiles, chosen at its boot menu, with no internet access needed.

## Install Profiles

| | `bare_metal` | `docker_vm` |
|---|---|---|
| **Use it for** | The first machine in an airgapped environment | A low-overhead Docker host in a VM |
| **Boots to** | `graphical.target` | `multi-user.target` |
| **Docker and CLI tools** | Yes | Yes |
| **GNOME desktop, RDP** | Yes | No |
| **KVM hypervisor, Cockpit** | Yes | No |
| **PXE server** | Yes | No |
| **Chrome, VS Code** | Yes | No |
| **Smart cards, DoD certificates, classification banner** | Yes | No |
| **Guest agents** | No | Yes (`qemu-guest-agent`, `open-vm-tools`) |

Both profiles install the same command-line tools: `baseline_packages` in
`bootstrap_server/defaults/main.yml`, including socat, screen, tmux, htop, nmap,
tcpdump, and jq.

The boot menu choice sets the OS packages and is stamped into
`/etc/bootstrap-pxe-release`. `bootstrap.sh` reads it and puts the host in the
matching Ansible inventory group. The role defaults describe `bare_metal`, and
`ansible/group_vars/docker_vm.yml` turns off what a Docker VM does not use.

On `bare_metal`, the host installs Rocky Linux, configures itself as an
infrastructure controller with Docker and Ansible, then runs a containerized PXE
server to network-boot other machines.

---

## How It Works

```
[Internet machine]          [Target machine]
  build-iso.sh   ─→  ISO  ─→  kickstart  ─→  bootstrap.sh  ─→  Ansible roles
  (online prep)        (boot)   (OS install)   (Docker + load)   (bootstrap + PXE)
```

1. **`build-iso.sh`** runs on any internet-connected machine. It downloads the Rocky
   9.8 ISO, Docker CE RPMs, ansible-runner image, builds PXE container images, and
   optionally downloads PXE client ISOs (Ubuntu, Rocky). Everything is packed into
   a custom bootable ISO.

2. Boot the target machine from the ISO. **Anaconda** runs `bootstrap.ks`:
   - `%pre` prompts for hostname and static IP
   - Installs Rocky 9.8 with LVM
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
| Rocky 9.8 DVD ISO | `download.rockylinux.org` | For installing the host OS |
| Docker CE RPMs | `download.docker.com` | docker-ce, cli, containerd, compose-plugin |
| EPEL packages | `dl.fedoraproject.org` | htop, iotop, iperf3, minicom, screen, ntfs-3g, ntfsprogs, exfatprogs, dosfstools, fuse3, xrdp, xorgxrdp, xrdp-selinux, and a newer SELinux policy for it + deps — packaged as a local dnf repo (repodata via `createrepo_c`); installed by name on the target |
| VS Code RPM + extensions | `update.code.visualstudio.com`, `marketplace.visualstudio.com` | Remote-SSH extension pack as VSIX files, pinned to stable versions. The RPM is always re-downloaded so it meets their minimum VS Code version |
| Google Chrome RPM | `dl.google.com` | Signature verified against Google's key at build time |
| DoD PKI certificates | `dl.dod.cyber.mil` | DISA's unclassified PKCS#7 bundle. Signed manifest verified at build time |
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

Write the ISO to USB, or attach it as virtual media (a VM's CD-ROM, or a server's
iDRAC or iLO), and boot. Both firmware types are supported. The boot menu offers one
entry per install profile:

- **Bootstrap Server (bare metal)**: default. The `bare_metal` profile.
- **Docker VM**: the `docker_vm` profile.

Both find the install media by its volume label (`BSTRAP_PXE`), so the same entries
work on CD, virtual media, and USB. The ISO is about 17 GB, so a USB stick must be at
least that size.

> **The install erases every disk the installer can see.** It protects the USB stick
> it booted from, but not other disks in the machine.

The installer reboots when it finishes. Leave the ISO attached, because it is the
package source. On a BIOS machine that boots the stick first, choose the hard disk in
the firmware boot menu. If you land back in this boot menu instead, nothing is erased
until you answer the network prompts.

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

Keep the ISO attached: it is the package source, and `bootstrap.sh` stops if it
cannot find it. This installs Docker, loads the container images, and runs Ansible
for the profile chosen at the boot menu. On completion it prints next steps:

1. **Change the admin password** (default is `password`): `passwd cloud`
2. On `bare_metal`, **open Cockpit**: `https://<IP>:9090`
3. On `bare_metal`, **connect over RDP**: `<IP>:3389`

Log out and back in to see the dynamic login banner with current system state.
The MOTD shows the **baseline release** the host was provisioned from. The
same info is in `/etc/bootstrap-pxe-release` (os-release format), written by
`bootstrap.ks` at install time from the repo's `VERSION` file:

```bash
cat /etc/bootstrap-pxe-release
# NAME="bootstrap-pxe"
# VERSION="1.3.0"
# BUILD_DATE="2026-04-28"
# PROFILE="bare_metal"
# INSTALLED="2026-04-28T14:32:11Z"
```

---

## Configuration

### Bootstrap server variables

Override in `ansible/group_vars/all.yml`, or `ansible/group_vars/docker_vm.yml` for
that profile only, or via `-e` flags:

| Variable | Default | What it installs / does |
|---|---|---|
| `bootstrap_admin_user` | `cloud` | Admin username created by Ansible |
| `bootstrap_admin_password` | `password` | Default password — **change in group_vars or vault** |
| `install_desktop` | `true` | GNOME, GDM, and the graphical boot target. `install_xrdp` needs this |
| `desktop_packages` | GNOME packages | Packages installed by `install_desktop`, including `brasero` |
| `install_hypervisor` | `true` | KVM, libvirt, and the management tools |
| `hypervisor_packages` | QEMU and libvirt packages | Packages installed by `install_hypervisor` |
| `hypervisor_services` | `virtqemud`, `virtnetworkd`, `virtstoraged` sockets | libvirt daemons to enable. Rocky 9 uses these rather than `libvirtd` |
| `install_guest_agents` | `false` | Agents that let a hypervisor manage this host. `true` on `docker_vm` |
| `guest_agent_packages` | `qemu-guest-agent`, `open-vm-tools` | Installed but not started: each runs only on its own hypervisor |
| `docker_packages` | `docker-ce`, `docker-ce-cli`, `containerd.io`, `docker-compose-plugin` | Packages installed from the Docker repo when `airgap_mode` is `false` |
| `install_baseline` | `true` | Full baseline tool set — see `baseline_packages` in `bootstrap_server/defaults/main.yml`. Includes base utilities, dev/build, network, monitoring, serial, and filesystem tools (NTFS / exFAT / FAT32 / ext4 / XFS). |
| `install_cockpit` | `true` | Enable cockpit.socket + firewall port 9090 |
| `install_classification_banner` | `false` | Install + lock the GNOME classification banner extension. See `class_level` and `classification_banners` in `bootstrap_server/defaults/main.yml`. Banner appears at next GNOME login (existing sessions need logout/login). |
| `class_level` | `UNCLASSIFIED` | Active classification level when the banner is installed. Must be a key in `classification_banners` (UNCLASSIFIED / CUI / CONFIDENTIAL / SECRET / TOP SECRET by default). Override per-host in inventory. |
| `install_k8s_tools` | `false` | kubectl, helm, k9s |
| `bootstrap_airgap_files_dir` | `/root/bootstrap/files` | Where the kickstart stages `files/` on the host. Read when `airgap_mode` is `true` |
| `install_smartcard` | `true` | Reader drivers + OpenSC, and the pcscd socket. Chrome picks up OpenSC automatically through p11-kit. Covers browser and app use of a CAC/PIV card, not smart card OS login |
| `smartcard_packages` | `pcsc-lite`, `pcsc-lite-ccid`, `opensc` | Packages installed by `install_smartcard` |
| `install_dod_certs` | `true` | Trust the DoD root + intermediate CAs system-wide and in Chrome. Chrome reads per-user NSS databases, so the admin user and `/etc/skel` are configured; accounts that already exist are not |
| `dod_certs_zip` | `unclass-certificates_pkcs7_DoD.zip` | Bundle file name. Keep in sync with `DOD_CERTS_URL` in `build-iso.sh` |
| `dod_certs_url` | `https://dl.dod.cyber.mil/.../{{ dod_certs_zip }}` | Bundle download URL. Used only when `airgap_mode` is `false` |
| `dod_certs_anchor` | `/etc/pki/ca-trust/source/anchors/dod-ca-bundle.pem` | Where the PEM bundle is installed |
| `install_google_chrome` | `true` | Install Google Chrome. Its online repo is disabled, so Chrome does not self-update |
| `google_chrome_rpm_url` | `https://dl.google.com/linux/direct/google-chrome-stable_current_x86_64.rpm` | RPM URL. Used only when `airgap_mode` is `false` |
| `install_vscode` | `true` | Install VS Code and `vscode_extensions` for the admin user |
| `vscode_extensions` | Remote-SSH pack | Extension IDs, in install order. Keep in sync with `VSCODE_EXTENSIONS` in `build-iso.sh`; `ms-vscode-remote.remote-ssh` must stay last |
| `vscode_extensions_dir` | `/opt/bootstrap/data/vscode-extensions` | Where VSIX files are staged so the admin user can read them |
| `install_xrdp` | `true` | RDP access from a Windows desktop: installs `xrdp_packages`, requires TLS, refuses root logins, sets the graphical boot target so sessions can lock, and opens 3389/tcp in firewalld, which must be running. See [Remote desktop](#remote-desktop) |
| `xrdp_packages` | `xrdp`, `xorgxrdp`, `xrdp-selinux` | Packages installed by `install_xrdp`. Keep in sync with `XRDP_PKGS` in `build-iso.sh`. `xrdp-selinux` must stay listed: without it the desktop fails under SELinux enforcing |

### PXE server variables

| Variable | Default | Purpose |
|---|---|---|
| `install_pxe_server` | `true` | Run the `pxe_server` role. `false` on `docker_vm` |
| `airgap_mode` | `true` | Skip ISO downloads, use pre-staged files |
| `dhcp_interface` | `eth0` | Network interface for dnsmasq |
| `dhcp_enabled` | `false` | false=proxyDHCP, true=standalone DHCP |
| `ubuntu2204_enabled` | `true` | Enable Ubuntu PXE boot entries |
| `rocky9_enabled` | `true` | Enable Rocky PXE boot entries |

### Remote desktop

Connect from Windows with Remote Desktop to `<host-ip>:3389` and log in as the
admin user. The session is GNOME on X11, with the classification banner.

- **NLA is not supported.** A Windows client whose policy requires Network Level
  Authentication will fail to connect.
- **Expect a certificate warning.** xrdp uses a self-signed certificate that it
  generates once, at install.
- **One session per user.** With a user at the console, an RDP login as that user
  connects and then drops about two seconds later with no message. With a user on
  RDP, including a disconnected session, the console login offers `Force Stop`,
  which ends the RDP session. Different users can be on at the same time.
- **Log noise.** `gsd-smartcard` logs repeated PC/SC refusals during RDP sessions.
  This is harmless. Smart cards are not available inside an RDP session.

### Re-running Ansible only

Once Docker is installed, re-run just the playbook:

```bash
cd /root/bootstrap
docker run --rm -i \
    --network host \
    -v "$(pwd):/runner" \
    -v /root/.ssh:/root/.ssh:ro \
    -w /runner/ansible \
    mma38e/ansible-runner:latest \
    ansible-playbook -i inventory.ini site.yml
```

`bootstrap.sh` already put the host in its profile's group, so no extra flags are
needed. Use `--tags packages`, `--tags compose`, etc. to target specific stages.

---

## Repository Structure

```
bootstrap-pxe/
├── build.sh                  Top-level entry — builds the builder, runs build-iso.sh inside
├── build-iso.sh              Online ISO build script (runs inside the builder container)
├── Dockerfile                Builder image (Rocky 9 + DinD + xorriso + isomd5sum + docker)
├── docker-entrypoint.sh      Boots dockerd inside the builder, then execs build-iso.sh
├── bootstrap.ks              Rocky 9.8 kickstart (injected into ISO)
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
│   ├── group_vars/docker_vm.yml  docker_vm profile: what it turns off
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
- Classification banner (login/GDM + Cockpit header banner, configurable level via group_vars)
- LibreOffice support (RPM group bundled for airgap; toggle via group_vars)

---

## Contributing

All changes must include updates to:
1. **`CHANGELOG.md`** — add an entry under today's version/date
2. **`AGENTS.md`** — update architecture or rules sections if applicable

See `AGENTS.md` for full developer rules.
