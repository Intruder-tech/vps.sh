#!/usr/bin/env bash
# Safe tests for vps.sh: syntax, lint, unit tests of pure functions, CLI
# parsing, and a host dry-run that must not change anything.
# Usage: bash tests/run_tests.sh
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT="$ROOT/vps.sh"
FIX="$ROOT/tests/fixtures"
PASS=0 FAIL=0
KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl test@example"

t_ok()   { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
t_fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; [[ -n ${2:-} ]] && printf '       %s\n' "$2"; }

# expect_eq NAME EXPECTED ACTUAL
expect_eq() { if [[ $2 == "$3" ]]; then t_ok "$1"; else t_fail "$1" "expected [$2] got [$3]"; fi; }
# expect_rc NAME EXPECTED_RC CMD...
expect_rc() {
  local name=$1 want=$2 rc=0; shift 2
  "$@" >/dev/null 2>&1 || rc=$?
  expect_eq "$name" "$want" "$rc"
}

# Run a snippet with vps.sh sourced (main is not executed when sourced).
in_lib() { bash -c "set -Eeuo pipefail; source '$SCRIPT'; $1" 2>&1; }

echo "== Static checks"
expect_rc "bash -n syntax" 0 bash -n "$SCRIPT"
if command -v shellcheck >/dev/null 2>&1; then
  expect_rc "shellcheck" 0 shellcheck -x "$SCRIPT"
elif command -v docker >/dev/null 2>&1 && docker image inspect koalaman/shellcheck:stable >/dev/null 2>&1; then
  expect_rc "shellcheck (docker)" 0 docker run --rm -v "$ROOT:/mnt:ro" koalaman/shellcheck:stable -x /mnt/vps.sh
else
  echo "  skip shellcheck (not installed)"
fi

echo "== OS detection"
detect() { in_lib "OS_RELEASE_FILE='$FIX/$1'; detect_os; echo \"\$OS_FAMILY \$PKG_MGR \$OS_SUPPORTED \$SUDO_GROUP\""; }
expect_eq "ubuntu 22.04"         "debian apt 1 sudo"  "$(detect ubuntu-22.04)"
expect_eq "debian 12"            "debian apt 1 sudo"  "$(detect debian-12)"
expect_eq "rocky 9"              "rhel dnf 1 wheel"   "$(detect rocky-9)"
expect_eq "fedora 40"            "rhel dnf 1 wheel"   "$(detect fedora-40)"
expect_eq "centos 7 unsupported" "rhel dnf 0 wheel"   "$(detect centos-7)"
expect_eq "mint via ID_LIKE"     "debian apt 0 sudo"  "$(detect mint-21)"
expect_eq "alpine unknown"       "unknown  0 "        "$(detect alpine-3.20)"
expect_rc "missing os-release"   1 in_lib "OS_RELEASE_FILE=/nonexistent; detect_os"

echo "== Validators"
expect_rc "username ok"          0 in_lib "valid_username deploy"
expect_rc "username root"        1 in_lib "valid_username root"
expect_rc "username uppercase"   1 in_lib "valid_username Deploy"
expect_rc "username injection"   1 in_lib "valid_username 'a;rm'"
expect_rc "pubkey ed25519"       0 in_lib "valid_pubkey '$KEY'"
expect_rc "pubkey garbage"       1 in_lib "valid_pubkey 'hello world'"
expect_rc "pubkey private key"   1 in_lib "valid_pubkey '-----BEGIN OPENSSH PRIVATE KEY-----'"
expect_eq "swap 2G"              "2048"  "$(in_lib 'size_to_mb 2G')"
expect_eq "swap 512m"            "512"   "$(in_lib 'size_to_mb 512m')"
expect_rc "swap too small"       1 in_lib "size_to_mb 100M"
expect_rc "swap bad unit"        1 in_lib "size_to_mb 2T"
expect_eq "ports normalize"      "80/tcp 443/tcp 51820/udp" "$(in_lib "normalize_ports '80, 443/tcp,51820/udp'")"
expect_eq "ports empty"          ""      "$(in_lib "normalize_ports ''")"
expect_rc "ports out of range"   1 in_lib "normalize_ports 70000"
expect_rc "ports garbage"        1 in_lib "normalize_ports '80;reboot'"
expect_rc "timezone UTC"         0 in_lib "valid_timezone UTC"
expect_rc "timezone traversal"   1 in_lib "valid_timezone ../../etc/passwd"

echo "== SSH lockout protection (ssh_policy ADMIN_READY ROOT_HAS_KEY)"
expect_eq "admin ready"          "no no"                  "$(in_lib 'ssh_policy 1 0')"
expect_eq "admin ready + root"   "no no"                  "$(in_lib 'ssh_policy 1 1')"
expect_eq "root key only"        "prohibit-password no"   "$(in_lib 'ssh_policy 0 1')"
expect_eq "no keys anywhere"     "keep keep"              "$(in_lib 'ssh_policy 0 0')"

echo "== authorized_keys parsing"
tmpd=$(mktemp -d); trap 'rm -rf "$tmpd"' EXIT
printf '%s\n' "$KEY" >"$tmpd/real"
printf 'no-port-forwarding,command="echo Please login as ubuntu;exit 142" %s\n' "$KEY" >"$tmpd/stub"
: >"$tmpd/empty"
expect_rc "real key usable"            0 in_lib "has_usable_key '$tmpd/real'"
expect_rc "cloud forced-command stub"  1 in_lib "has_usable_key '$tmpd/stub'"
expect_rc "empty file"                 1 in_lib "has_usable_key '$tmpd/empty'"
expect_rc "missing file"               1 in_lib "has_usable_key '$tmpd/nope'"

echo "== CLI parsing"
expect_rc "--help"                     0 bash "$SCRIPT" --help
expect_eq "--version"                  "vps.sh 1.0.0" "$(bash "$SCRIPT" --version)"
expect_rc "unknown option"             2 bash "$SCRIPT" --bogus
expect_rc "bad username"               2 bash "$SCRIPT" -y -n --admin-user ROOT
expect_rc "bad key"                    2 bash "$SCRIPT" -y -n --admin-user deploy --ssh-key "nope"
expect_rc "bad ports"                  2 bash "$SCRIPT" -y -n --open-ports "80;x"
expect_rc "bad swap"                   2 bash "$SCRIPT" -y -n --swap-size 9T
expect_rc "missing value"              2 bash "$SCRIPT" -y -n --admin-user
expect_rc "key without admin user"     2 bash "$SCRIPT" -y -n --ssh-key "$KEY"
printf '# comment\n%s\n' "$KEY" >"$tmpd/keys.pub"
expect_eq "key file parsed" "$KEY" "$(in_lib "parse_args -y --admin-user d --ssh-key '$tmpd/keys.pub'; echo \"\$SSH_PUBKEYS\"")"
expect_eq "flags" "unattended 1 0 1 80/tcp" \
  "$(in_lib "parse_args --yes --dry-run --no-firewall --with-docker --open-ports 80; echo \"\$MODE \$DRY_RUN \$DO_FIREWALL \$DO_DOCKER \$OPEN_PORTS\"")"
expect_rc "interactive without tty"    2 setsid -w bash "$SCRIPT" --dry-run

echo "== Dry-run on this host (must change nothing)"
watch=(/etc/ssh/sshd_config.d /etc/fail2ban /etc/apt/apt.conf.d /etc/sudoers.d /etc/fstab /etc/passwd)
snap() { find "${watch[@]}" -maxdepth 1 -type f -exec md5sum {} + 2>/dev/null | sort; swapon --show --noheadings 2>/dev/null; }
before=$(snap)
log_before=$(stat -c %s /var/log/vps-bootstrap.log 2>/dev/null || echo none)
out=$(bash "$SCRIPT" --dry-run --yes --force --with-docker --admin-user vpstestuser --ssh-key "$KEY" \
      --open-ports 80,443 --timezone UTC 2>&1); rc=$?
expect_eq "dry-run exit code" 0 "$rc"
[[ $out == *"Dry-run complete. Nothing was changed."* ]] && t_ok "dry-run summary" || t_fail "dry-run summary" "$(tail -5 <<<"$out")"
[[ $out == *"[DRY-RUN] "*"useradd"* ]] && t_ok "dry-run shows useradd" || t_fail "dry-run shows useradd"
[[ $out == *"PasswordAuthentication no"* ]] && t_ok "dry-run plans key-only SSH" || t_fail "dry-run plans key-only SSH"
expect_eq "no files changed"   "$before" "$(snap)"
expect_eq "log not written"    "$log_before" "$(stat -c %s /var/log/vps-bootstrap.log 2>/dev/null || echo none)"
expect_rc "test user not created" 1 id vpstestuser

echo
echo "Passed: $PASS  Failed: $FAIL"
(( FAIL == 0 ))
