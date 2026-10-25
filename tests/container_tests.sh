#!/usr/bin/env bash
# Real (non-dry-run) installs inside throwaway Docker containers, one per
# supported distro. Never touches the host. Containers have no systemd, so
# --force is used and service-only steps (firewall, fail2ban, swap, SSH reload)
# are disabled; package installs, user creation, sudoers and config files run for real.
# Usage: [DOCKER_NETWORK=bridge] bash tests/container_tests.sh [image ...]
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl test@example"
IMAGES=("$@")
(( ${#IMAGES[@]} )) || IMAGES=(ubuntu:22.04 ubuntu:24.04 debian:12 rockylinux:9 almalinux:9 fedora:40)
NET=${DOCKER_NETWORK:-host}   # host network: some hosts have no outbound route on the docker bridge
PASS=0 FAIL=0

for img in "${IMAGES[@]}"; do
  printf '== %s ... ' "$img"
  out=$(docker run --rm --network "$NET" -v "$ROOT/vps.sh:/vps.sh:ro" "$img" bash -c "
    set -e
    bash /vps.sh --dry-run --yes --force >/tmp/dry.out 2>&1 || { echo DRYRUN_FAILED; cat /tmp/dry.out; exit 1; }
    bash /vps.sh --yes --force --no-firewall --no-fail2ban --no-swap --no-ssh-hardening \
      --admin-user deploy --ssh-key '$KEY' --sudo-nopasswd --timezone UTC >/tmp/run.out 2>&1 \
      || { echo RUN_FAILED; tail -40 /tmp/run.out; tail -40 /var/log/vps-bootstrap.log; exit 1; }
    # Assertions
    command -v git jq htop tmux sudo >/dev/null
    id -nG deploy | grep -Eqw 'sudo|wheel'
    grep -qF '$KEY' /home/deploy/.ssh/authorized_keys
    [ \"\$(stat -c %a /home/deploy/.ssh)\" = 700 ]
    [ \"\$(stat -c %a /home/deploy/.ssh/authorized_keys)\" = 600 ]
    visudo -cf /etc/sudoers.d/90-vps-sh-deploy >/dev/null
    su deploy -c 'sudo -n true'
    if [ -d /etc/apt ]; then grep -q 'Unattended-Upgrade \"1\"' /etc/apt/apt.conf.d/20auto-upgrades;
    else grep -q 'upgrade_type = security' /etc/dnf/automatic.conf; fi
    # Idempotency: second run must succeed and not duplicate the key
    bash /vps.sh --yes --force --no-upgrade --no-firewall --no-fail2ban --no-swap --no-ssh-hardening \
      --admin-user deploy --ssh-key '$KEY' >/tmp/run2.out 2>&1 || { echo RERUN_FAILED; tail -30 /tmp/run2.out; exit 1; }
    [ \"\$(grep -cF '$KEY' /home/deploy/.ssh/authorized_keys)\" = 1 ]
    echo ALL_ASSERTIONS_PASSED
  " 2>&1)
  if [[ $out == *ALL_ASSERTIONS_PASSED* ]]; then
    PASS=$((PASS + 1)); echo ok
  else
    FAIL=$((FAIL + 1)); echo FAIL; tail -40 <<<"$out" | sed 's/^/    /'
  fi
done

echo "Passed: $PASS  Failed: $FAIL"
(( FAIL == 0 ))
