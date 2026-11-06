# AGENTS.md — Bootstrap + PXE Server Repository Guide

This file describes the repository architecture, conventions, and developer rules for
AI agents and human contributors. It must be kept up to date as the repo evolves.

---

## Repository Purpose

`bootstrap-pxe` is a self-contained kit that installs a Rocky Linux 9.8 machine from
one ISO, with no internet access, as one of two **install profiles** chosen at the
boot menu:

- `bare_metal`: an infrastructure bootstrap node, hypervisor, **and** PXE boot server
  with a GNOME desktop. It is the **first machine** in an airgapped environment — it
  hosts the `ansible-runner` container, drives Ansible against all other machines,
  and PXE-boots them over the network.
- `docker_vm`: a low-overhead Docker host in a VM, on `multi-user.target`.

This repo combines what was previously `bootstrap-server` and `pxe-server` into a
single project with two Ansible roles.

---

## Architecture Overview

```
bootstrap-pxe/
│
├── build.sh              ← ENTRY POINT: builds the local builder image and
│                           runs build-iso.sh inside it. Use this, not
│                           build-iso.sh, on the internet-connected machine.
│
├── Dockerfile            ← Builder image (Rocky 9 + DinD + xorriso + isomd5sum
│                           + docker-ce). Built locally by build.sh.
│
├── docker-entrypoint.sh  ← Boots dockerd inside the builder, then execs the
│                           ISO build. Used as the image ENTRYPOINT.
│
├── build-iso.sh          ← ONLINE PREP: invoked *inside* the builder container
│                           by build.sh. Downloads Rocky ISO + deps, builds PXE
│                           containers, optionally downloads PXE client ISOs,
│                           repackages into a custom bootable ISO.
│
├── bootstrap.ks          ← KICKSTART: embedded in the ISO by build-iso.sh.
│                           Runs during Anaconda install. %pre reads the install
│                           profile, writes its package list, and prompts for
│                           static IP. %post (--nochroot) copies all artifacts
│                           to /root/bootstrap/ and stamps the profile.
│
├── bootstrap.sh          ← POST-INSTALL: run as root after first login.
│                           Installs Docker CE from local RPMs, loads all
│                           container images, then runs Ansible for the profile.
│
├── docker-compose.yml    ← PXE container stack (dhcp, tftp, http)
│
├── docs/
│   └── pxe-server-fixes.md ← Planned PXE fixes and xrdp work, not yet implemented
│
├── containers/           ← PXE container Dockerfiles
│   ├── dhcp/             ← alpine + dnsmasq (proxyDHCP or standalone)
│   ├── tftp/             ← multi-stage: ubuntu (grub/syslinux) → alpine (tftpd)
│   └── http/             ← nginx:alpine (serves ISOs, kickstarts, cloud-init)
│
├── files/                ← AIRGAP ARTIFACTS (gitignored, populated by build-iso.sh)
│   ├── images/           ← ansible-runner.tar + pxe-images.tar
│   ├── certs/dod/        ← DISA PKCS#7 bundle zip, verified at build time
│   ├── vscode-extensions/ ← Remote-SSH extension pack VSIX files
│   ├── rpms/             ← Docker CE, EPEL, VS Code, and Chrome RPMs
│   │   ├── docker/
│   │   ├── epel/         ← x86_64/noarch only, with repodata/ (createrepo_c) —
│   │   │                   registered by bootstrap.sh as the local-epel dnf repo
│   │   ├── vscode/
│   │   └── chrome/
│   └── isos/             ← PXE client ISOs (Ubuntu, Rocky) — optional
│
└── ansible/              ← Full machine + PXE configuration via Ansible
    ├── site.yml          ← Main playbook (runs both roles in sequence)
    ├── inventory.ini     ← Host entry with __BOOTSTRAP_IP__ placeholder
    ├── inventory.example ← Template for customisation
    ├── group_vars/
    │   ├── all.yml       ← SSH settings, bootstrap vars, PXE vars
    │   └── docker_vm.yml ← docker_vm profile: turns off what it does not use
    └── roles/
        ├── bootstrap_server/           ← Role 1: Host setup
        │   ├── defaults/main.yml       ← Tool toggles + defaults
        │   ├── tasks/
        │   │   ├── main.yml            ← Orchestration (imports + tags)
        │   │   ├── packages.yml        ← Tool installation
        │   │   ├── docker.yml          ← Docker install, service, group
        │   │   ├── directories.yml     ← /opt/bootstrap tree
        │   │   ├── users.yml           ← Admin user, sudo
        │   │   ├── services.yml        ← httpd, tftp, sshd
        │   │   ├── desktop.yml         ← GNOME, GDM, graphical boot target
        │   │   ├── hypervisor.yml      ← KVM, libvirt, management tools
        │   │   ├── guest_agents.yml    ← qemu-guest-agent, open-vm-tools
        │   │   ├── smartcard.yml       ← Reader drivers, OpenSC, pcscd
        │   │   ├── dod_certs.yml       ← DoD CAs into the system trust store
        │   │   ├── nssdb.yml           ← DoD CAs into Chrome's per-user NSS dbs
        │   │   ├── chrome.yml          ← Chrome, with its online repo disabled
        │   │   ├── vscode.yml          ← VS Code + extensions for the admin user
        │   │   └── xrdp.yml            ← xrdp, its hardening, and 3389/tcp
        │   ├── files/configure-nssdb.sh ← Idempotent NSS CA import
        │   ├── files/xrdp-sesman.pam    ← GNOME login stack for RDP sessions
        │   ├── templates/motd.j2
        │   └── handlers/main.yml
        │
        └── pxe_server/                 ← Role 2: PXE service setup
            ├── defaults/main.yml       ← Profiles, ISO URLs, DHCP defaults
            ├── tasks/
            │   ├── main.yml            ← docker → dirs → boot_files → configs → compose
            │   ├── docker.yml          ← Docker CE install (skips if present)
            │   ├── directories.yml     ← /opt/pxe-server bind-mount tree
            │   ├── boot_files.yml      ← ISO copy/download + kernel extraction
            │   ├── configs.yml         ← Render templates (grub, kickstart, cloud-init)
            │   └── compose.yml         ← Build check + docker compose up
            ├── templates/
            │   ├── env.j2
            │   ├── grub.cfg.j2         ← EFI boot menu
            │   ├── pxelinux.cfg_default.j2  ← BIOS boot menu
            │   ├── kickstart/*.ks.j2   ← Rocky kickstart profiles
            │   └── cloud-init/*/       ← Ubuntu autoinstall profiles
            └── handlers/main.yml
```

---

## Setup Flow

```
[Internet machine]
  1. ./build.sh
       ↓ docker build of the local builder image (Rocky 9 + DinD + iso tools)
       ↓ docker run --privileged → dockerd starts inside → build-iso.sh runs
       ↓ prompts: root password, ansible-runner image tag, include PXE ISOs?
       ↓ downloads: Rocky 9.8 ISO, Docker CE RPMs, EPEL packages (x86_64/noarch
         + repodata built with createrepo_c), VS Code RPM + extensions, Chrome
         RPM (signature verified), DoD certificates (signed manifest verified)
       ↓ pulls + saves: ansible-runner image
       ↓ builds + saves: PXE container images (pxe-dhcp, pxe-tftp, pxe-http)
       ↓ optionally downloads: Ubuntu 22.04 + Rocky 9 ISOs for PXE clients
       ↓ produces: bootstrap-pxe-<date>.iso

[Target machine — boot from ISO]
  2. Anaconda kickstart (bootstrap.ks)
       ↓ boot menu entry sets bootstrap.profile= on the kernel command line
       ↓ %pre: validates the profile, writes /tmp/packages.ks for %packages,
         prompts for hostname + static IP
       ↓ installs Rocky 9.8 with LVM
       ↓ %post: copies bootstrap.sh, ansible/, files/, containers/,
         docker-compose.yml to /root/bootstrap/, writes PROFILE= to
         /etc/bootstrap-pxe-release

[Target machine — after reboot]
  3. cd /root/bootstrap && ./bootstrap.sh
       ↓ disables internet repos, mounts ISO as local repos (local-baseos,
         local-appstream) and registers files/rpms/epel as local-epel
       ↓ installs EPEL packages by name from local-epel
       ↓ installs Docker CE from local RPMs
       ↓ docker load ansible-runner.tar + pxe-images.tar (bare_metal only)
       ↓ injects host IP + profile group into inventory, IP into group_vars
       ↓ docker run ansible-runner → ansible-playbook site.yml

  4. Ansible roles
       ↓ bootstrap_server: packages, Docker, users, dirs, services, then what
         the profile enables: desktop, hypervisor, guest agents, smart cards,
         DoD certs, Chrome, VS Code, xrdp
       ↓ pxe_server (bare_metal only): stage ISOs, extract kernels, render
         configs, compose up

  5. bare_metal: PXE server running — clients can now network boot
     docker_vm: Docker host ready
```

---

## Key Conventions

### Install profiles
A profile is a package list in `bootstrap.ks` plus a set of toggles. Role defaults
describe `bare_metal`. `group_vars/docker_vm.yml` turns off what a Docker VM does not
use, and it wins over `group_vars/all.yml` because the host is in that inventory
group. To add a profile: add a case to `%pre` in `bootstrap.ks`, a boot menu entry in
`build-iso.sh`, the name in the `bootstrap.sh` profile check, and a
`group_vars/<profile>.yml`. `ksvalidator` cannot see inside `/tmp/packages.ks`, so a
misspelled group only fails at install: test each profile.

### Two roles, one playbook
The `bootstrap_server` and `pxe_server` roles are kept independent. They can
be run together (default) or individually using tags. `pxe_server` runs only when
`install_pxe_server` is true. Its docker.yml harmlessly skips when Docker is already
present: `bootstrap_server` owns the Docker install.

### Airgap mode
The `airgap_mode` variable (default `true` in group_vars) controls whether
`pxe_server/tasks/boot_files.yml` downloads ISOs from the internet or copies
them from the staging directory (`airgap_iso_staging_dir`). The bootstrap_server
Chrome, VS Code, and DoD certificate tasks follow the same split, reading from
`bootstrap_airgap_files_dir` when it is `true`. xrdp resolves by name from
`local-epel` when it is `true`, and enables online EPEL when it is `false`.

### Variables and toggles
All package installation is controlled by boolean toggles in
`ansible/roles/bootstrap_server/defaults/main.yml`. PXE configuration uses
variables in `ansible/roles/pxe_server/defaults/main.yml`.

### Variable placement
- **Role defaults** (`defaults/main.yml`): base values shipped with each role.
- **group_vars/all.yml**: site-specific overrides — SSH settings, admin user,
  PXE network config, OS toggles, extra profiles.
- **group_vars/docker_vm.yml**: overrides for that install profile only.

### Profile system (PXE)
- Base profiles: `rocky9_profiles`, `ubuntu2204_profiles` — in pxe_server defaults.
- Extra profiles: `rocky9_extra_profiles`, `ubuntu2204_extra_profiles` — in group_vars.
- Each Rocky profile needs a `templates/kickstart/<name>.ks.j2`.
- Each Ubuntu profile needs a `templates/cloud-init/<name>/` directory.

### Ansible pattern
- Role-based composition with `import_tasks` + tags
- Centralized defaults, no hardcoded values in task files
- Handler-based service restarts
- **Never use `localhost` or `ansible_connection=local`** — ansible-runner runs
  inside a Docker container. Always target the host by IP address.

### Airgap artifacts
The `files/` directory is gitignored. It is populated entirely by `build-iso.sh`.
Never commit RPMs, images, or ISOs.

### ansible-runner
All Ansible is run from the `mma38e/ansible-runner` Docker container (UBI9-based,
Galaxy collections pre-installed). Invoked via `docker run` in `bootstrap.sh`.

---

## Developer Rules

> **All contributors (human and AI) must follow these rules on every change.**

1. **Bump `VERSION` and add a versioned `CHANGELOG.md` section at PR-merge
   time** — the merging commit (squash commit on the integration branch)
   bumps the top-level `VERSION` file to the new release and adds a
   `## [X.Y.Z] — YYYY-MM-DD` section documenting that PR's changes. Format
   inside the section: `- <type>: <description>` where type is `add`, `fix`,
   `change`, `remove`. **Do not** accumulate entries under an `[Unreleased]`
   heading during development — the changelog only describes what shipped.
   `VERSION` is the single source of truth: `build-iso.sh` reads it and
   `bootstrap.ks` stamps it onto each provisioned host as
   `/etc/bootstrap-pxe-release`.

2. **Update `AGENTS.md`** — if you add a new file, change the setup flow, or
   modify the architecture, update the relevant section here.

3. **No internet dependencies in Ansible tasks** — all packages must be
   installable from local RPMs or the ISO. PXE ISO downloads must respect
   the `airgap_mode` variable.

4. **Preserve idempotency** — every Ansible task must be safe to run twice.

5. **Test kickstart syntax** — run `ksvalidator bootstrap.ks` before committing.

6. **Bash scripts** — run `bash -n <script>` before committing. Scripts must
   `set -euo pipefail`.

7. **Secrets** — never commit passwords, keys, or hashes.

8. **No localhost in inventory** — always target the host by IP address.

9. **Keep it simple** — prefer the simplest approach that works. Follow proven
   patterns. Simple, readable code is always preferred over clever abstractions.

10. **Document every new variable** — any variable added to `defaults/main.yml`
    must appear in `README.md` under the Configuration table with its default
    value and purpose. This keeps the README the single source of truth for
    operators customising the deployment.

11. **Ansible roles are the source of truth for host state** — every package,
    service, user, file, or config the host needs must be declared in the role
    itself (e.g. `baseline_packages` in `bootstrap_server/defaults/main.yml`).
    Pre-installation work done by `bootstrap.sh` (EPEL RPMs, Docker CE, image
    loads) is a cold-boot **optimization** for the airgap path, never a
    substitute for an Ansible task. Two consequences for every change:

    - If `bootstrap.sh` installs something, the role must also declare it.
      Removing the bootstrap.sh step alone must not break the host's final
      state — a clean Ansible run from a fresh Rocky 9 host with package
      repos available must converge to the same end state.
    - Tasks must remain idempotent so re-running on a host where bootstrap.sh
      already did the work is a no-op (rule #4 reinforces this).

    Goal: the Ansible roles are runnable standalone, both for testing on a
    non-airgapped lab box and for re-converging an existing bootstrap host.
