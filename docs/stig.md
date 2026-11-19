# DISA STIG hardening

Work in progress on `feature/stig`. This records the plan, baseline scores, and the
open items found so far. Exceptions will move to `docs/stig-exceptions.md`.

## Approach

- **Apply:** the `ansible-lockdown` RHEL9-STIG role, version 2.9.0 (STIG V2R9), from
  the ansible-runner image. `ansible/stig.yml` will import it, with overrides in
  `ansible/group_vars/stig.yml`, and `site.yml` will import that playbook.
- **Measure:** `stig-scan`, using OpenSCAP and the DVD's SCAP Security Guide
  (`stig_gui` on `bare_metal`, `stig` on `docker_vm`).
- **Scope:** both install profiles. FIPS on, which needs `rhel9stig_disruption_high`.
  Rocky Linux is acceptable to the assessor.

## Baseline scores (unhardened)

Scanned 2026-11-08 with `stig-scan`, after `bootstrap.sh`, before any hardening. SCAP
Security Guide 0.1.80 from the Rocky 9.8 DVD.

| Profile | Scan profile | Score | Pass | Fail | N/A | CAT I fail | CAT II fail | CAT III fail |
|---|---|---|---|---|---|---|---|---|
| `docker_vm` | `stig` | 46.1% | 164 | 272 | 40 | 15 | 235 | 19 |
| `bare_metal` | `stig_gui` | 45.5% | 171 | 279 | 22 | 18 | 238 | 20 |

After the signature-check fix (2026-11-19), before any STIG hardening:

| Profile | Score | Pass | Fail | Signature rules |
|---|---|---|---|---|
| `docker_vm` | 46.6% | 167 | 269 | All 3 pass |
| `bare_metal` | 45.9% | 174 | 276 | All 3 pass |

CAT I failures, both profiles unless noted:

| Rule | Expected after step 2 |
|---|---|
| `enable_fips_mode`, `enable_dracut_fips_module`, `sysctl_crypto_fips_enabled`, `configure_crypto_policy`, `harden_sshd_ciphers_openssh_conf_crypto_policy` | Fixed by FIPS mode |
| `ensure_gpgcheck_local_packages`, `ensure_gpgcheck_never_disabled` | Fixed on `feature/stig`: every package is signature-checked. The build ships each vendor's key beside its RPMs and fails on any RPM that is not signed by it |
| `grub2_password`, `grub2_admin_username` | Open until the GRUB password placeholder is set |
| `no_empty_passwords`, `sshd_disable_empty_passwords` | Expected from the role |
| `disable_ctrlaltdel_reboot`, `disable_ctrlaltdel_burstaction` | Expected from the role |
| `dconf_gnome_disable_restart_shutdown`, `dconf_gnome_disable_ctrlaltdel_reboot`, `gnome_gdm_disable_automatic_login` (`bare_metal` only) | Expected from the role |
| `installed_OS_is_vendor_supported`, `ensure_redhat_gpgkey_installed` | Probably permanent on Rocky: they look for RHEL. For the assessor |

## Decided

| Item | Rules | Decision |
|---|---|---|
| FIPS mode | 671010 | On |
| IPv4/IPv6 forwarding | 253075, 254025 | Exception: Docker and libvirt need it |
| USB mass storage, USBGuard | 291010–291030 | Exception: hosts can be installed and served from USB |
| CAC login | 611160, 611165, 611170 | Not enforced |
| Separate filesystems | 231015–231035 | Not done (CAT III) |
| Audit disk full and disk error actions | 653020, 653025 | Not done |
| DNS, NTP, remote syslog, GRUB password | 252035, 252040, others | Placeholders in `group_vars/stig.yml`, rules off until set |

## Open items for step 2

Found by review of step 1, against the 2.9.0 role source:

- **Sudo:** 611085 rewrites every `NOPASSWD` to `PASSWD`. `rhel9stig_sudoers_exclude_nopasswd_list`
  must list `ansible`, or Ansible loses sudo partway through the STIG run. Overriding
  the list replaces its defaults (`ec2-user`, `vagrant`).
- **wheel:** `users.yml` adds `%wheel ALL=(ALL) NOPASSWD: ALL`. 611085 rewrites it, and
  the role adds it back, so the two fight on every run. Decide: drop it when the STIG
  is on, so people in `wheel` use sudo with a password.
- **Root SSH:** `bootstrap.ks` writes `PermitRootLogin yes` to
  `/etc/ssh/sshd_config.d/01-permitrootlogin.conf`, and drop-ins win over
  `sshd_config`. The role's loop that should comment drop-ins out does not, so the
  STIG playbook must remove this file itself, or 255045 stays a finding.
- **User namespaces:** 213105 may break Chrome's sandbox. Test before deciding.
- **Package updates:** 211015 updates everything, and `local-epel` holds newer base
  libraries swept in by `dnf download --resolve`. Keep that repo out of the update.
- **DNS:** the role's default writes `8.8.8.8` into NetworkManager. Keep 252035 off
  until a site value is set.

## Signature checks

Every package the host installs is signature-checked, which the CAT I rules
`ensure_gpgcheck_local_packages` and `ensure_gpgcheck_never_disabled` require:

| Source | Key on the ISO | Checked at build |
|---|---|---|
| DVD (BaseOS, AppStream) | Rocky key, already installed on every host | No: the DVD is Rocky's own |
| `files/rpms/epel/` | `RPM-GPG-KEY-EPEL-9` from the builder's `epel-release`, plus the Rocky key for the Rocky packages there | Every RPM |
| `files/rpms/docker/` | `docker-ce.gpg` | Every RPM |
| `files/rpms/vscode/` | `microsoft.asc` | Every RPM |
| `files/rpms/chrome/` | `linux_signing_key.pub` | Every RPM |

`bootstrap.sh` turns `gpgcheck=1` on for the local repos and sets `localpkg_gpgcheck=1`
in `dnf.conf`; the role declares the same and imports each key.

Not covered: the PXE client kickstarts in `pxe_server` still set `gpgcheck=0`. They
configure the machines this host installs, not the host, so they belong with the PXE
work.

## Done in step 1

- Ansible logs in as a key-only `ansible` account instead of root. Its key is ECDSA,
  because FIPS rejects ed25519, and it never expires. `bootstrap.sh` repairs its
  sudoers line on every run.
- `stig-scan` installed on both profiles.
