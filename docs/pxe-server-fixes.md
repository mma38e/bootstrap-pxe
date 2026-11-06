# PXE server fixes and xrdp: planned changes

Nothing here is implemented yet. This records what has to change before
`bootstrap-pxe` can serve PXE clients. It comes from testing the 1.5.0 ISO on
UEFI and BIOS VMs with no network, plus a code review.

Evidence labels:

- **VM**: reproduced on an installed VM.
- **Review**: found by reading the code. Not reproduced.

## Blocking: the PXE stack does not come up

### 1. A missing PXE client ISO stops the whole run (VM)

With no ISOs staged, the play fails at `Copy pre-staged Ubuntu 22.04 ISO` and
`bootstrap.sh` exits 2, straight after telling the operator that ISOs can be
added later. The ISOs are never embedded in the bootstrap ISO, so this hits every
install where they were not copied over first.

| Where | Setting today | Change |
|---|---|---|
| `ansible/roles/pxe_server/tasks/boot_files.yml:22` | Copy assumes the Ubuntu ISO exists | `stat` it first, and skip the copy and extraction with a warning if absent |
| `ansible/roles/pxe_server/tasks/boot_files.yml:88` | Same for the Rocky ISO | Same |
| `ansible/roles/pxe_server/templates/grub.cfg.j2`, `pxelinux.cfg_default.j2` | Menus render from `ubuntu2204_enabled` and `rocky9_enabled` | Leave out any OS whose ISO is absent, so clients are not offered a dead entry |

Current workaround: set both `*_enabled` values to `false` in
`ansible/group_vars/all.yml`.

### 2. `pxe-dhcp` crash-loops on any host without an `eth0` (VM)

dnsmasq exits with `unknown interface eth0`. The VM's interface was `enp0s2`.

| Where | Setting today | Change |
|---|---|---|
| `ansible/group_vars/all.yml:22` | `dhcp_interface: "eth0"` | Remove the override |
| `ansible/roles/pxe_server/defaults/main.yml:10` | `dhcp_interface: "eth0"` | Find the interface holding `pxe_server_ip` from Ansible facts. Do not rely on the default route: an airgapped network may not have one |
| `docker-compose.yml:32`, `containers/dhcp/entrypoint.sh:17` | Fall back to `eth0` | Fail with a clear message instead of guessing |

### 3. A crash-looping stack is reported as success (VM)

`bootstrap.sh` printed its setup-complete message while `pxe-dhcp` was
restarting.

| Where | Change |
|---|---|
| `ansible/roles/pxe_server/tasks/compose.yml` | After `up`, check the containers are still running, and fail the play if one is not |

### 4. The firewall blocks DHCP, proxyDHCP, and TFTP (VM)

The VM had only `cockpit`, `dhcpv6-client`, and `ssh` open. `pxe-dhcp` and
`pxe-tftp` use `network_mode: host`, so their traffic goes through the host
firewall. `pxe-http` publishes port 80 through Docker's own rules and is
reachable; whether it needs a firewall rule of its own should be confirmed with
a real client.

| Where | Setting today | Change |
|---|---|---|
| New `ansible/roles/pxe_server/tasks/firewall.yml` | No PXE firewall tasks exist | Open 67/udp, 4011/udp, and 69/udp |
| `ansible/roles/pxe_server/tasks/main.yml` | No firewall step | Import it before `compose.yml` |

Do not copy the `ignore_errors: true` from `bootstrap_server/tasks/services.yml`.
A failure here must stop the play. `bootstrap_server` only opens tftp when
`install_services` is true, which stays off.

## Blocking: clients cannot install

### 5. The default Rocky kickstart does not parse (Review)

| Where | Setting today | Change |
|---|---|---|
| `ansible/roles/pxe_server/templates/kickstart/rocky9.ks.j2:5` | `install` command, removed from the RHEL 9 kickstart syntax | Delete the line |

### 6. The cockpit kickstart needs packages the DVD does not have (Review)

| Where | Setting today | Change |
|---|---|---|
| `ansible/roles/pxe_server/templates/kickstart/rocky9-cockpit-server.ks.j2:40-41` | `screen` and `htop`, both EPEL only | Remove them, or also serve the EPEL repo to clients |

### 7. BIOS Rocky clients have no kernel to load (Review)

The menu loads `/boot/rocky9/vmlinuz` and `initrd.img` over TFTP, but nothing
creates that directory. EFI clients load over HTTP and are not affected.

| Where | Setting today | Change |
|---|---|---|
| `ansible/roles/pxe_server/tasks/boot_files.yml:98` | Rocky tree goes to the webroot only | Also copy `images/pxeboot/vmlinuz` and `initrd.img` to `tftpboot/boot/rocky9/` |
| `ansible/roles/pxe_server/templates/pxelinux.cfg_default.j2:32-33, 38-39` | Expects those paths | No change once the files exist |

## Should fix

### 8. Every re-run restarts `pxe-tftp` and `pxe-http` (Review)

`Fix ownership of data directories` forces mode 0755 on every file, later tasks
set 0644, and that notifies the restart handlers. A re-run during a client
install could interrupt it. This breaks AGENTS.md rule 4.

| Where | Setting today | Change |
|---|---|---|
| `ansible/roles/pxe_server/tasks/directories.yml:82` | `mode: "0755"` with `recurse: true` | Set ownership only, and leave modes to the tasks that create the files |

### 9. The wrong host IP can be stored permanently (Review)

`hostname -I` runs after Docker has started, so with no usable NIC address the
result is `172.17.0.1`. That passes the empty check in `bootstrap.sh` Step 5 and
ends up in the inventory and in `pxe_server_ip`.

| Where | Change |
|---|---|
| `bootstrap.sh` Step 5 | Take the address from the real interface, and reject Docker bridge addresses |

### 10. The installed host loses its package source on reboot (VM, partly)

The ISO is not in `/etc/fstab`, so it was unmounted after a reboot while the
`local-baseos` and `local-appstream` repos still pointed at it. Whether `dnf
install` then fails was not determined: the test package was already installed.
Test that first. If it fails, add a `nofail` fstab entry or remount in the role.

### 11. Docs (Review)

| Where | Setting today | Change |
|---|---|---|
| `README.md:206` | Documents `--tags pxe`, which matches no task | Use the real tags: `boot_files`, `configs`, `compose` |
| `build-iso.sh`, end-of-build summary | Says the kickstart needs no interaction | Mention the hostname and network prompts |

## Test plan

Rebuild the ISO, answer `y` to the PXE client ISO prompt, and repeat both VM
installs. Then add what has not been tested yet: real PXE client VMs, UEFI and
BIOS, booting from the server over an isolated network. QEMU's user-mode network
used so far cannot carry DHCP broadcasts between VMs, so this needs a socket or
bridge network with no route out. Run `bootstrap.sh` twice on each server, once
with ISOs staged and once without.

## xrdp: remote desktop from Windows

Requested so a Windows desktop can RDP into the host. Not started.

Likely changes:

| Where | Change |
|---|---|
| `build-iso.sh` and `bootstrap.sh`, `EPEL_PKGS` | Add `xrdp` and `xorgxrdp`. Both are in EPEL 9 and neither is on the DVD |
| `ansible/roles/bootstrap_server/defaults/main.yml` | Add an `install_xrdp` toggle, documented in `README.md` (rule 10) |
| New `ansible/roles/bootstrap_server/tasks/xrdp.yml` | Install the packages, enable the services, and open 3389/tcp (rule 11) |
| `ansible/roles/bootstrap_server/tasks/main.yml` | Import it under an `xrdp` tag |

To work out first:

- **Desktop session:** the test VMs booted to `multi-user.target`, and a GNOME RDP
  session has not been tried. Confirm it works from the packages the ISO installs.
- **Classification banner:** confirm it appears in an RDP session, since xrdp uses
  an X session and the banner has only been described for local GNOME.
- **Concurrent logins:** decide what happens when the same user is signed in at
  the console and over RDP.
- **Access:** decide which networks may reach 3389/tcp, and whether xrdp's default
  self-signed certificate is acceptable.
- **Smart cards:** check whether a CAC or PIV card on the Windows desktop needs to
  work inside the RDP session. This is untested and would need its own work.

## Other open items

Not PXE, recorded so they are not lost:

- `configure-nssdb.sh` never removes a CA dropped from a newer DoD bundle, so
  Chrome's databases on existing hosts can keep trusting it.
- Remote-SSH needs a VS Code Server on the machine it connects to, and that is not
  bundled. Connecting to an airgapped machine does not work out of the box.
- `ansible/roles/bootstrap_server/tasks/directories.yml:19` sets `.ssh` to 0750
  and `users.yml:34` sets it to 0700, so both report a change on every run.
- `build-iso.sh:182` exits silently if the Rocky CHECKSUM fetch fails, so the
  warning branch after it never runs.
- A failed `xorriso` run is hidden, and the 40 GB disk check is below what a 9.8
  build needs, so a truncated ISO can be reported as ready.
- The 9.8 ISO URLs use the rolling `/pub/rocky/9/` path, so they will return 404
  when Rocky 9.9 ships, as the 9.7 URLs did.
