# Changelog

All notable changes to `bootstrap-pxe` are documented here.
Format: `- <type>: <description>` — types: `add`, `fix`, `change`, `remove`.

Changelog sections are added **at PR-merge time** alongside a `VERSION` bump
in the same commit; there is no `[Unreleased]` rolling section. The current
release is whatever `VERSION` says — that value is also stamped onto every
provisioned host at install time as `/etc/bootstrap-pxe-release`. See
`AGENTS.md` rule #1.

---

## [1.3.0] — 2026-04-28

### Added
- add: top-level `VERSION` file as the single source of truth for the
  baseline release. Bumped at PR-merge time alongside a CHANGELOG section
  per the new AGENTS.md rule #1.
- add: per-host baseline stamp at `/etc/bootstrap-pxe-release`, written by
  `bootstrap.ks` `%post` from `__BASELINE_VERSION__` and `__BASELINE_BUILD_DATE__`
  tokens substituted by `build-iso.sh` (alongside the existing `__ROOT_PW_HASH__`).
  File is in os-release format (NAME / VERSION / BUILD_DATE / INSTALLED) so
  operators and tooling can identify the baseline a host was provisioned from.
- add: `Baseline:` line in the bootstrap MOTD (`motd.j2`) sourcing
  `/etc/bootstrap-pxe-release` so the version is visible at every login.
- add: second boot menu entry "Bootstrap Install (USB)" in the output ISO's
  isolinux + GRUB EFI configs. Uses `inst.repo=hd:LABEL=BSTRAP_PXE` and
  `inst.ks=hd:LABEL=BSTRAP_PXE:/bootstrap.ks` so installs from USB written by
  Rufus (DD mode) work without needing a CD-ROM device. The original entry is
  retained as "Bootstrap Install (CD-ROM)" and remains the default.
- add: `ISO_LABEL="BSTRAP_PXE"` constant in `build-iso.sh` — short,
  FAT32-compatible (≤11 chars) volume label applied to the output ISO via
  `xorriso -V`. Replaces the inherited 20-char Rocky label that Rufus would
  truncate or rewrite on USB write.

### Changed
- change: `bootstrap.ks` no longer specifies `cdrom` as the install source.
  Anaconda picks the source from `inst.repo=` in the boot menu entry, so the
  same kickstart serves both CD-ROM and USB boot paths (one source of truth).
- change: `build-iso.sh` boot-menu generation now uses unquoted heredocs and
  expands `${ISO_LABEL}` into the isolinux and grub.cfg entries instead of
  hardcoding `Rocky-9-7-x86_64-dvd`.
- change: `README.md` Step 2 documents the two boot menu entries and recommends
  Rufus DD mode for USB writes; Step 3 points operators at
  `/etc/bootstrap-pxe-release` for baseline version info.
- change: `AGENTS.md` rule #1 rewritten — changelog entries are added at
  PR-merge time alongside a `VERSION` bump (no rolling `[Unreleased]` block).
- add: `install_classification_banner` toggle and `class_level` /
  `classification_banners` vars in `bootstrap_server/defaults/main.yml` (default
  off; default level `UNCLASSIFIED`). When enabled, installs Rocky/RHEL 9's
  `gnome-shell-extension-classification-banner` package and applies a
  system-wide dconf profile (`/etc/dconf/db/local.d/`) with the level's
  message + colors. Settings are locked so non-root users cannot alter or
  disable them. Wayland-native — no X11 fallback needed.
- add: `tasks/classification_banner.yml`, `templates/dconf-classification-banner.j2`,
  and a `dconf update` handler in `bootstrap_server/handlers/main.yml`.
- add: `Configure classification banner` import in `tasks/main.yml`, gated by
  the toggle and tagged `[banner]`.

### Notes
- Color presets ship for UNCLASSIFIED (green), CUI (purple), CONFIDENTIAL
  (blue), SECRET (red), TOP SECRET (orange). Add or override entries in
  `classification_banners` for site-specific levels.
- The role does not actively remove the banner if the toggle is later set to
  `false`. Operators removing the banner should `dnf remove` the package and
  delete `/etc/dconf/db/local.d/00-classification-banner` and the matching
  lock file by hand, then `dconf update`.
- TODO: verify `classification_banner_uuid` (`classification-banner@gnome-shell-extensions.gcampax.github.com`)
  and the GSettings schema keys against a real Rocky 9 install on first boot
  test; adjust `defaults/main.yml` and the template if RHEL's package uses a
  different UUID or key set.

---

## [1.2.0] — 2026-04-25

### Added
- add: `Dockerfile` at repo root — Rocky 9 + DinD builder image with `xorriso`,
  `isomd5sum`, `docker-ce`, `docker-compose-plugin`, and `docker-buildx-plugin`.
  Replaces the requirement to install ISO build tooling on the host.
- add: `docker-entrypoint.sh` — boots `dockerd` with `overlay2` inside the
  builder container, waits for readiness, then execs `build-iso.sh`.
- add: `build.sh` — top-level wrapper that builds the local builder image and
  runs `build-iso.sh` inside it (`--privileged`, named volume
  `bootstrap-pxe-builder-cache` for `/var/lib/docker` to persist image cache
  between local runs). New supported entry point for ISO builds.
- add: `.dockerignore` — limits the build context to `Dockerfile` +
  `docker-entrypoint.sh`; keeps the context under 1 KB.

### Changed
- change: `README.md` — Prerequisites now requires only Docker on the host;
  Step 1 documents `./build.sh` as the entry point; Repository Structure
  reflects the new files.

---
## [1.1.5] — 2026-04-23

### Added
- add: filesystem support packages (ntfs-3g, ntfsprogs, exfatprogs, dosfstools,
  e2fsprogs, xfsprogs, fuse3) to the baseline package set — userspace tools +
  drivers for NTFS, exFAT, FAT32, ext4, XFS volumes.
- add: ntfs-3g, ntfsprogs, exfatprogs, dosfstools, fuse3 to the EPEL bundle in
  `build-iso.sh` so filesystem support is installable on the airgapped target.
- add: `baseline_packages` and `services_packages` named lists in
  `bootstrap_server/defaults/main.yml` — declarative single source of truth for
  package sets, consumed by `packages.yml`.
- add: developer rule #11 in `AGENTS.md` — Ansible roles are the source of
  truth for host state. Pre-installation in `bootstrap.sh` is a cold-boot
  optimization, not a substitute. Roles must remain runnable standalone.

### Changed
- change: collapsed `install_base_tools`, `install_dev_tools`, `install_network_tools`,
  `install_monitoring_tools`, `install_serial_tools`, and `install_filesystem_tools`
  into a single `install_baseline` toggle (default `true`). Replaces six per-group
  `dnf` tasks in `packages.yml` with one single-transaction call that consumes
  `baseline_packages`. Faster install, simpler vars, single resolver pass.
- change: `containers/tftp/Dockerfile` builder stage now installs `grub-efi-amd64-bin`
  via apt and copies `grubnetx64.efi` from `/usr/lib/grub/x86_64-efi/monolithic/`
  instead of `wget`-ing it from `archive.ubuntu.com`. GPG-verified, consistent
  with the syslinux/pxelinux pattern in the same stage. No runtime behavior change.

### Removed
- remove: per-group install toggles (`install_base_tools`, `install_dev_tools`,
  `install_network_tools`, `install_monitoring_tools`, `install_serial_tools`,
  `install_filesystem_tools`). **Breaking for any inventory that overrides these
  to `false`** — migrate to `install_baseline: false` and add desired packages via
  a custom task or extra var. Repo-internal grep confirms no current overrides.

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
