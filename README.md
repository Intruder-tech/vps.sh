# vps.sh

Production-safe bootstrap installer for a fresh VPS. One Bash script with two modes:

- **Interactive** (default): asks about each component, shows the plan, and asks you to confirm before it changes anything.
- **Unattended** (`--yes`): no prompts. It uses command-line flags and safe defaults, for cloud-init and automation.

Add `--dry-run` to either mode. It prints every command and file write, and changes nothing.

## Supported systems

| Family | Distributions | Package manager |
|---|---|---|
| Debian | Ubuntu 20.04+, Debian 11+ | apt |
| RHEL | RHEL / Rocky / AlmaLinux 8–10, CentOS Stream 9+, Fedora 39+ | dnf |

The script detects the OS from `/etc/os-release`. Derivatives (for example Linux Mint) are detected through `ID_LIKE` but need `--force`.

## Included software

| Component | Debian/Ubuntu | RHEL family | Default |
|---|---|---|---|
| System upgrade | `apt-get upgrade` | `dnf upgrade` | on |
| Base tools | ca-certificates curl wget git vim htop unzip jq gnupg tmux rsync logrotate sudo, systemd-timesyncd | same set (vim-enhanced, gnupg2, tar), chrony, EPEL | on |
| Automatic security updates | unattended-upgrades | dnf-automatic | on |
| Firewall | ufw | firewalld | on |
| Brute-force protection | fail2ban (sshd jail) | fail2ban (from EPEL) | on |
| Swap file | `/swapfile`, swappiness 10 | same | on, only if no swap exists |
| Admin user | sudo group, SSH keys | wheel group, SSH keys | off (opt-in) |
| SSH hardening | `sshd_config.d` drop-in | same | on, gated (see below) |
| Docker Engine + Compose plugin | official Docker repo | official Docker repo | off (opt-in) |

## Safety behavior

- **Preflight checks** run before any change: root, Bash 4+, OS and version, CPU architecture, systemd, free disk, memory, DNS and mirror reachability, package locks, and SSH ports. A hard failure stops the run. You can override soft failures with `--force`.
- **No SSH lockout.**
  - Password login is disabled only when an account can still log in with a key and reach root. That account is either an admin user with a key and working sudo, or root with a key.
  - Cloud "please login as ubuntu" forced-command stubs do not count as working keys.
  - The new config is checked with `sshd -t` before reload. If the check fails, the script removes the new config.
- **The firewall allows all current SSH ports before it turns on.** This includes the port of the session you are connected through.
- **No reboots and no SSH port changes.** The `sshd_config` main file is never edited, and the summary tells you if a reboot is needed.
- Writes are atomic. Each changed file gets a backup named `*.vps-sh.<timestamp>.bak`, and managed files are tagged `Managed by vps.sh`.
- Re-running the script is safe: it does not duplicate keys, fstab lines, or firewall rules.
- A lock file stops two runs at once. Everything is logged to `/var/log/vps-bootstrap.log` (mode 600).
- If one step fails, the remaining steps still run. The summary reports the failure and the exit code is 1. SSH hardening is skipped if the admin-user step failed.

## Quick install

```bash
# Preview (no changes), then run interactively
curl -fsSL https://enlo.online/vps.sh | sudo bash -s -- --dry-run --yes
curl -fsSL https://enlo.online | sudo bash

# Unattended, with flags after `--`
curl -fsSL https://enlo.online/vps.sh | sudo bash -s -- --yes --admin-user deploy --copy-root-keys

# Verify before running
curl -fsSLO https://enlo.online/vps.sh && curl -fsSL https://enlo.online/vps.sh.sha256 | sha256sum -c - && sudo bash vps.sh
```

Interactive prompts read from `/dev/tty`, so they work when the script is piped from `curl`.

## Usage

```bash
# Preview without changes
sudo bash vps.sh --dry-run

# Interactive
sudo bash vps.sh

# Unattended
sudo bash vps.sh --yes --admin-user deploy --copy-root-keys --open-ports 80,443 --timezone UTC
sudo bash vps.sh --yes --admin-user deploy --ssh-key ~/.ssh/id_ed25519.pub --sudo-nopasswd --with-docker
```

Run `bash vps.sh --help` to see all flags, including the `--no-<component>` switches, `--swap-size`, `--log-file` and `--force`.

Exit codes: `0` success, `1` a step failed, `2` usage error, `3` preflight failed.

After any run that hardens SSH, **keep your current session open**. Open a new terminal and confirm you can log in, for example with `ssh deploy@<server-ip>`, before you disconnect.

To revert SSH hardening, run `rm /etc/ssh/sshd_config.d/01-vps-sh-hardening.conf && systemctl reload ssh` (the service is `sshd` on the RHEL family).

> Docker-published ports bypass ufw/firewalld. Bind containers to `127.0.0.1` unless a port should be public.

## Tests

```bash
bash tests/run_tests.sh        # syntax, shellcheck, unit tests, CLI parsing, host dry-run (changes nothing)
bash tests/container_tests.sh  # real installs in throwaway Docker containers (ubuntu 22.04/24.04, debian 12, rocky 9, alma 9, fedora 40)
```

The container tests use Docker host networking by default (`--network host`), because some VPS hosts have no outbound route on the default Docker bridge. To use the bridge instead, run `DOCKER_NETWORK=bridge bash tests/container_tests.sh`. You can also pass specific images, for example `bash tests/container_tests.sh debian:12`.

`run_tests.sh` checksums key files in `/etc` before and after a dry-run to prove nothing changed. `container_tests.sh` never touches the host. It runs a real install in each container, checks the result, and runs the install a second time to prove it is idempotent. Containers have no systemd, so firewall, fail2ban, swap and the SSH reload are covered by unit tests and dry-run only.
