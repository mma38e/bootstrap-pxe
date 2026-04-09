# Changelog

All notable changes to `bootstrap-pxe` are documented here.
Format: `- <type>: <description>` — types: `add`, `fix`, `change`, `remove`

---

## [1.1.0] — 2026-04-09

### Added
- add: `bootstrap_admin_password` variable in `bootstrap_server/defaults/main.yml`
  (default `"password"`). Set via group_vars or vault. Password is applied with
  `update_password: on_create` so re-running the playbook never resets a manually
  changed password.
- add: `install_cockpit` / `cockpit_enabled` toggle in `bootstrap_server/defaults/main.yml`
  (default `true`). Enables `cockpit.socket` and opens firewall port 9090.
- add: cockpit tasks and handler to `bootstrap_server/tasks/services.yml` and
  `handlers/main.yml`.
- add: `/etc/profile.d/bootstrap-motd.sh` — replaces static `/etc/motd` with a bash
  script that computes hostname, IP, uptime, Docker and Cockpit status at login time.
  Includes post-setup quick reference (password change, Cockpit URL, graphical target).
- add: developer rule #10 in AGENTS.md: all new `defaults/main.yml` variables must be
  documented in `README.md`.

### Changed
- change: `bootstrap.sh` completion message now prints next steps (change password,
  Cockpit URL, optional graphical target switch).
- change: `tasks/main.yml` deploys `motd.j2` to `/etc/profile.d/bootstrap-motd.sh`
  (mode 0755) and clears `/etc/motd` so the dynamic script runs at interactive login.

---

## [1.0.0] — 2026-04-08

Combined `bootstrap-server` and `pxe-server` into a single repository.

### Added
- add: `pxe_server` Ansible role (from pxe-server repo) — deploys containerized
  PXE boot services (dnsmasq, tftpd-hpa, nginx) via docker compose.
- add: `containers/` directory with Dockerfiles for pxe-dhcp, pxe-tftp, pxe-http.
- add: `docker-compose.yml` for the PXE container stack.
- add: `airgap_mode` variable in `group_vars/all.yml` — when true, pxe_server role
  copies pre-staged ISOs instead of downloading them from the internet.
- add: `build-iso.sh` now builds PXE container images and saves as pxe-images.tar.
- add: `build-iso.sh` optionally downloads PXE client ISOs (Ubuntu 22.04, Rocky 9).
- add: `bootstrap.sh` loads PXE container images and injects pxe_server_ip into
  group_vars.
- add: `bootstrap.ks` %post now copies containers/, docker-compose.yml, and PXE
  client ISOs to /root/bootstrap/.

### Changed
- change: repo renamed from `bootstrap-server` to `bootstrap-pxe`.
- change: `site.yml` now runs both `bootstrap_server` and `pxe_server` roles.
- change: `group_vars/all.yml` merged to include PXE server variables.
- change: output ISO renamed from `bootstrap-server-*.iso` to `bootstrap-pxe-*.iso`.

### Removed
- remove: `scripts/airgap-bundle.sh` — superseded by `build-iso.sh`.
- remove: `scripts/airgap-deploy.sh` — superseded by ISO + `bootstrap.sh`.
- remove: `run-playbook.sh` — superseded by `bootstrap.sh`.

---

## [0.2.0] — 2026-04-08

### Fixed
- fix: kickstart only honors one `@^` environment group — `@^virtualization-host-environment`
  was overriding `@^graphical-server-environment`, so GNOME/GDM never installed.
  Replaced with `@virtualization-hypervisor` and `@virtualization-tools` regular groups
  so `@^graphical-server-environment` takes effect as the single environment group.
- fix: `%post` now uses `--nochroot` so it can access the ISO mount at
  `/run/install/repo`. Previously the default chroot prevented copying bootstrap
  artifacts, leaving `/root/bootstrap/` empty after install.
- fix: removed `install` keyword from `bootstrap.ks` (removed in RHEL 9, caused
  Anaconda parse error on line 6).
- fix: GRUB boot menu missing newline separator between injected menuentry and
  existing entries.
- fix: checksum fetch in `build-iso.sh` now uses canonical DVD filename regardless
  of download URL (supports mirrors/proxies).

### Changed
- change: `bootstrap.sh` now disables default internet repos and mounts the local
  ISO as BaseOS/AppStream dnf repos before installing packages (airgap-safe).
- change: inventory no longer uses `localhost` / `ansible_connection=local`.
  ansible-runner runs in a container so must SSH to the host by IP. `inventory.ini`
  uses `__BOOTSTRAP_IP__` placeholder, replaced at runtime by `bootstrap.sh`.
- change: moved inventory variables (`ansible_user`, `ansible_ssh_extra_args`,
  `bootstrap_admin_user`, `bootstrap_project_dir`) from `inventory.ini` to
  `ansible/group_vars/all.yml`.
- change: `build-iso.sh` now downloads actual EPEL RPMs (htop, iotop, iperf3,
  minicom, screen) with dependencies via `dnf download --resolve`, instead of just
  the `epel-release` repo config package (useless in airgap).
- change: EPEL packages are installed by `bootstrap.sh` via `dnf localinstall`
  before Ansible runs. Removed `Enable EPEL repository` task from Ansible role.
- change: moved `minicom` from network tools to serial/terminal tools group
  alongside `screen` in `packages.yml`.
- change: `bootstrap.ks` `%pre` rewritten to use proven tty6 exec/chvt pattern
  from reference kickstart file.

### Added
- add: `PermitRootLogin yes` via `/etc/ssh/sshd_config.d/01-permitrootlogin.conf`
  in kickstart `%post` (needed for ansible-runner SSH access).
- add: `ansible/group_vars/all.yml` for centralized variable management (SSH
  settings, admin user, project dir).
- add: `bootstrap.sh` mounts `/root/.ssh` into the ansible-runner container for
  SSH key access.
- add: developer rule #8 in AGENTS.md: no localhost in inventory.

---

## [0.1.0] — 2026-04-07

Initial implementation of the bootstrap server provisioning kit.

### Added
- `build-iso.sh`: online ISO preparation script. Downloads Rocky 9.7 minimal ISO,
  Docker CE RPMs, EPEL release, and ansible-runner container image. Injects all
  artifacts and the kickstart into a custom bootable ISO. Runs disk space checks
  (≥40 GB required) and verifies ISO sha256 checksum.
- `bootstrap.ks`: Rocky Linux 9.7 kickstart file. Interactive `%pre` section
  prompts for hostname and static IP configuration. LVM partitioning with a
  dedicated `/var` volume for Docker storage. `%post` copies bootstrap artifacts
  from the ISO into `/root/bootstrap/`.
- `bootstrap.sh`: post-install phase 1 script. Installs Docker CE from local RPMs
  (airgap-safe), loads the ansible-runner container image, runs the Ansible playbook
  via explicit `docker run`.
- `ansible/site.yml`: main Ansible playbook targeting `bootstrap_servers` group.
- `ansible/inventory.ini`: localhost inventory using `ansible_connection=local`.
- `ansible/inventory.example`: annotated inventory template.
- `ansible/roles/bootstrap_server/`: full Ansible role with tasks for packages,
  Docker, directories, users, and services. Tool installation controlled by boolean
  toggles in `defaults/main.yml`. Includes MOTD template and service handlers.
- `AGENTS.md`: repository architecture reference and developer rules (all contributors
  must update `CHANGELOG.md` and `AGENTS.md` on every change).
- `.gitignore`: excludes `files/` (airgap artifacts), `work/` (build scratch), and
  output ISOs from version control.
