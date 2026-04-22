# AGENTS.md — Bootstrap + PXE Server Repository Guide

This file describes the repository architecture, conventions, and developer rules for
AI agents and human contributors. It must be kept up to date as the repo evolves.

---

## Repository Purpose

`bootstrap-pxe` is a self-contained kit to provision a Rocky Linux 9.7 machine as
an infrastructure bootstrap node **and** PXE boot server. It is the **first machine**
in an airgapped environment — it hosts the `ansible-runner` container, drives Ansible
against all other machines, and PXE-boots them over the network.

This repo combines what was previously `bootstrap-server` and `pxe-server` into a
single project with two Ansible roles.

---

## Architecture Overview

```
bootstrap-pxe/
│
├── build-iso.sh          ← ONLINE PREP: run on internet-connected machine
│                           Downloads Rocky ISO + deps, builds PXE containers,
│                           optionally downloads PXE client ISOs, repackages
│                           into a custom bootable ISO.
│
├── bootstrap.ks          ← KICKSTART: embedded in the ISO by build-iso.sh.
│                           Runs during Anaconda install. %pre prompts for
│                           static IP. %post (--nochroot) copies all artifacts
│                           to /root/bootstrap/.
│
├── bootstrap.sh          ← POST-INSTALL: run as root after first login.
│                           Installs Docker CE from local RPMs, loads all
│                           container images, then runs both Ansible roles.
│
├── docker-compose.yml    ← PXE container stack (dhcp, tftp, http)
│
├── containers/           ← PXE container Dockerfiles
│   ├── dhcp/             ← alpine + dnsmasq (proxyDHCP or standalone)
│   ├── tftp/             ← multi-stage: ubuntu (grub/syslinux) → alpine (tftpd)
│   └── http/             ← nginx:alpine (serves ISOs, kickstarts, cloud-init)
│
├── files/                ← AIRGAP ARTIFACTS (gitignored, populated by build-iso.sh)
│   ├── images/           ← ansible-runner.tar + pxe-images.tar
│   ├── rpms/             ← Docker CE + EPEL RPMs
│   │   ├── docker/
│   │   ├── epel/
│   │   └── vscode/
│   └── isos/             ← PXE client ISOs (Ubuntu, Rocky) — optional
│
└── ansible/              ← Full machine + PXE configuration via Ansible
    ├── site.yml          ← Main playbook (runs both roles in sequence)
    ├── inventory.ini     ← Host entry with __BOOTSTRAP_IP__ placeholder
    ├── inventory.example ← Template for customisation
    ├── group_vars/
    │   └── all.yml       ← SSH settings, bootstrap vars, PXE vars
    └── roles/
        ├── bootstrap_server/           ← Role 1: Host setup
        │   ├── defaults/main.yml       ← Tool toggles + defaults
        │   ├── tasks/
        │   │   ├── main.yml            ← Orchestration (imports + tags)
        │   │   ├── packages.yml        ← Tool installation
        │   │   ├── docker.yml          ← Docker service + group
        │   │   ├── directories.yml     ← /opt/bootstrap tree
        │   │   ├── users.yml           ← Admin user, sudo
        │   │   └── services.yml        ← httpd, tftp, sshd
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
  1. ./build-iso.sh
       ↓ prompts: root password, ansible-runner image tag, include PXE ISOs?
       ↓ downloads: Rocky 9.7 ISO, Docker CE RPMs, EPEL packages
       ↓ pulls + saves: ansible-runner image
       ↓ builds + saves: PXE container images (pxe-dhcp, pxe-tftp, pxe-http)
       ↓ optionally downloads: Ubuntu 22.04 + Rocky 9 ISOs for PXE clients
       ↓ produces: bootstrap-pxe-<date>.iso

[Target machine — boot from ISO]
  2. Anaconda kickstart (bootstrap.ks)
       ↓ %pre: prompts for hostname + static IP
       ↓ installs Rocky 9.7 with LVM
       ↓ %post: copies bootstrap.sh, ansible/, files/, containers/,
         docker-compose.yml to /root/bootstrap/

[Target machine — after reboot]
  3. cd /root/bootstrap && ./bootstrap.sh
       ↓ disables internet repos, mounts ISO as local repos
       ↓ installs EPEL packages + VS Code from local RPMs
       ↓ installs Docker CE from local RPMs
       ↓ docker load ansible-runner.tar + pxe-images.tar
       ↓ injects host IP into inventory + group_vars
       ↓ docker run ansible-runner → ansible-playbook site.yml

  4. Ansible roles
       ↓ bootstrap_server: packages, Docker service, users, dirs, services
       ↓ pxe_server: stage ISOs, extract kernels, render configs, compose up

  5. PXE server running — clients can now network boot
```

---

## Key Conventions

### Two roles, one playbook
The `bootstrap_server` and `pxe_server` roles are kept independent. They can
be run together (default) or individually using tags. The pxe_server role's
docker.yml harmlessly skips when Docker is already present.

### Airgap mode
The `airgap_mode` variable (default `true` in group_vars) controls whether
`pxe_server/tasks/boot_files.yml` downloads ISOs from the internet or copies
them from the staging directory (`airgap_iso_staging_dir`).

### Variables and toggles
All package installation is controlled by boolean toggles in
`ansible/roles/bootstrap_server/defaults/main.yml`. PXE configuration uses
variables in `ansible/roles/pxe_server/defaults/main.yml`.

### Variable placement
- **Role defaults** (`defaults/main.yml`): base values shipped with each role.
- **group_vars/all.yml**: site-specific overrides — SSH settings, admin user,
  PXE network config, OS toggles, extra profiles.

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

1. **Update `CHANGELOG.md`** — add an entry for every change. Format:
   `- <type>: <description>` where type is `add`, `fix`, `change`, `remove`.

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
