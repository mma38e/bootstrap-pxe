# STIG exceptions and open findings

Every DISA STIG rule that `ansible/group_vars/stig.yml` turns off, and why. Rule
IDs are from the RHEL 9 STIG V2R9, as implemented by the ansible-lockdown
RHEL9-STIG role 2.9.0. Severity: CAT I is high, CAT II medium, CAT III low.

Status:

- **Exception:** an approved deviation, needed for what the host does.
- **Finding (POA&M):** an open finding with a plan to close it.
- **Placeholder:** off only until a site value is set. Closing it is a configuration
  change, not a code change.

Keep this file in step with `ansible/group_vars/stig.yml`.

## Exceptions

| Rule | CAT | Requirement | Reason | Mitigation |
|---|---|---|---|---|
| RHEL-09-253075 | II | No IPv4 packet forwarding unless a router | Docker bridge networking and libvirt NAT forward packets | The firewall's DROP zone still governs traffic to the host |
| RHEL-09-254025 | II | No IPv6 packet forwarding unless a router | As above | As above |
| RHEL-09-291010 | II | USB mass storage disabled | Hosts are installed from, and keep using, a USB stick as their package source | Physical access control |
| RHEL-09-291015, 291020, 291025, 291030 | II, III | USBGuard installed, enabled, logging, blocking unknown devices | Would block the USB install stick and smart card readers | As above |
| RHEL-09-611160, 611165, 611170 | II | CAC smart card authentication | CAC login is not required on these hosts | Password and key authentication under the STIG's password rules |
| RHEL-09-611085 | II | A password for privilege escalation | Only for the `ansible` service account, which runs Ansible unattended | Key-only login with an ECDSA key generated per host; the account has no password and cannot log in any other way |
| RHEL-09-215035 | II | No packages from EPEL | `xrdp`, `htop`, `screen`, and filesystem tools come from EPEL. The rule would also fail the play, by disabling a repo named `epel` that does not exist here | Every EPEL package comes from the local `local-epel` repo and is signature-checked against the EPEL key at build time and on install |
| RHEL-09-213105 | II | User namespaces disabled | Setting them to 0 stops systemd sandboxing services (`irqbalance` fails to start), and forces Chrome onto its setuid sandbox, which SELinux denies. Both profiles are container hosts | SELinux enforcing confines services and containers |
| RHEL-09-211030, 215070 | II | No graphical display manager unless approved | `bare_metal` is a GUI bootstrap server. `docker_vm` has no GUI and stays compliant | The GUI is approved on `bare_metal` only (`rhel9stig_gui_approved`) |

## Open findings (POA&M)

| Rule | CAT | Requirement | Why open | Plan |
|---|---|---|---|---|
| RHEL-09-212020 | **I** | A unique superusers name for single-user and maintenance mode | Needs a GRUB password, which is a secret and cannot be committed | Add a build-time prompt for a GRUB password, hashed into the ISO like the root password |
| RHEL-09-212010 | II | A boot loader superuser password | As above | As above |
| RHEL-09-231010 | II | Separate filesystem for `/home` | The kickstart puts everything on one root filesystem | Add LVM volumes to `bootstrap.ks` when the disk layout is revisited |
| RHEL-09-231015 | II | Separate filesystem for `/tmp` | As above | As above |
| RHEL-09-231035 | II | Separate filesystem for `/var/tmp` | As above | As above |
| RHEL-09-231020 | III | Separate filesystem for `/var` | As above | As above |
| RHEL-09-231025 | III | Separate filesystem for `/var/log` | As above | As above |
| RHEL-09-231030 | III | Separate filesystem for the audit data path | As above | As above |
| RHEL-09-653020 | II | Audit action on a disk error | The role would set `HALT`, which stops a host with one root filesystem when it fills | Revisit with the separate audit filesystem |
| RHEL-09-653025 | II | Audit action when the audit volume is full | As above | As above |
| RHEL-09-653050 | II | Audit action when space left reaches the admin threshold | The role would switch to single-user mode at 5% free, cutting off SSH, RDP, and Ansible on a host with one root filesystem | As above |
| RHEL-09-211015 | II | Vendor security patches installed | A full update from the local repos would mix newer libraries from `local-epel` with the DVD's | Patch by rebuilding the ISO from current Rocky media |
| RHEL-09-433015 | II | `fapolicyd` enabled | With Rocky's stock rules, `fapolicyd` denies `runc`, which Docker runs from an in-memory copy, so no container starts. That includes ansible-runner, so Ansible itself stops working | Build a `fapolicyd` rule set that allows `runc`, test it with Docker, the PXE stack, and ansible-runner, then enable it. Installed (433010) but stopped until then |
| RHEL-09-433016 | II | `fapolicyd` deny-all, permit-by-exception | Left at the role's default (`rhel9stig_allow_fapolicy_updates: false`), so the deny-all rule is not added. `fapolicyd` still runs with Rocky's stock rules | Test with Docker, the PXE containers, and `stig-scan`, then build an allow list |

## Role defects

Turned off because the ansible-lockdown role mishandles them in this environment.
`stig-scan` still measures each one.

| Rule | CAT | Requirement | Defect |
|---|---|---|---|
| RHEL-09-232240 | II | World-writable directories owned by a system account | The role only audits this rule. Its `find` over every filesystem fails the play when a directory vanishes mid-scan, such as a user session's `/run/user/<uid>` |

The role also writes the DoD banner (RHEL-09-171011, 211020, 271010) with paragraph
breaks, which are invalid in GNOME's dconf database and make every `dconf update`
fail. `group_vars/stig.yml` passes the same text with its whitespace collapsed to
single spaces. The rule is still applied.

## Placeholders

The role's defaults point at public servers that do not exist on an airgapped
network, so each rule stays off until the site value is set in
`ansible/group_vars/stig.yml`.

| Rule | CAT | Requirement | Value needed |
|---|---|---|---|
| RHEL-09-252035 | II | At least two DNS servers | `rhel9stig_dns_ip4_servers` |
| RHEL-09-252040 | II | A DNS processing mode in NetworkManager | Set with the DNS servers |
| RHEL-09-252020 | II | Compare clocks with an authoritative time source | `rhel9stig_time_synchronization_servers` |
| RHEL-09-652055 | II | Forward audit records to another system | `rhel9stig_rsyslog_remote_server_ip`, `_port`, `_protocol`, plus the TLS `rhel9stig_rsyslog_stream_driver*` settings and certificates |

## Expected to fail on Rocky Linux

These look for Red Hat Enterprise Linux and are expected to fail in an OpenSCAP
scan of Rocky Linux, which the assessor has accepted:

- `installed_OS_is_vendor_supported` (CAT I)
- `ensure_redhat_gpgkey_installed` (CAT I)
