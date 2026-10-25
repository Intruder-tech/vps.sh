#!/usr/bin/env bash
#
# vps.sh - production-safe VPS bootstrap installer
#
# Modes:
#   interactive (default)    asks about each component, confirms before changing anything
#   unattended  (-y/--yes)   no prompts; uses command-line flags and safe defaults
# Add -n/--dry-run to either mode to print every change without making it.
#
# Supported: Ubuntu 20.04+, Debian 11+, RHEL/Rocky/AlmaLinux 8-10,
#            CentOS Stream 9+, Fedora 39+.
#
# Exit codes: 0 success, 1 a step failed, 2 usage error, 3 preflight failed.

set -Eeuo pipefail

readonly VPS_SH_VERSION="1.0.0"
readonly MANAGED_TAG="Managed by vps.sh"

# ---------------------------------------------------------------------------
# Defaults (safe for production: nothing destructive, no reboot, no SSH port
# change, password login only disabled when a working key login exists)
# ---------------------------------------------------------------------------
MODE="interactive"
DRY_RUN=0
FORCE=0
LOG_FILE="/var/log/vps-bootstrap.log"
OS_RELEASE_FILE="${OS_RELEASE_FILE:-/etc/os-release}"
LOCK_FILE="/run/lock/vps-sh.lock"

DO_UPGRADE=1
DO_BASE=1
DO_AUTO_UPDATES=1
DO_FIREWALL=1
DO_FAIL2BAN=1
DO_SWAP=1
DO_SSH_HARDEN=1
DO_DOCKER=0

SWAP_SIZE="2G"
ADMIN_USER=""
SSH_PUBKEYS=""      # newline-separated public keys
COPY_ROOT_KEYS=0
SUDO_NOPASSWD=0
TIMEZONE=""
OPEN_PORTS=""       # normalized: "80/tcp 443/tcp"

# Detected state
OS_ID="" OS_LIKE="" OS_VERSION_ID="" OS_MAJOR="" OS_NAME="" OS_CODENAME=""
OS_FAMILY="" PKG_MGR="" OS_SUPPORTED=0 SUDO_GROUP=""
SSH_PORTS=()
PREFLIGHT_FAILS=0
STATE_DIR=""
STEP_RESULTS=()

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------
setup_colors() {
  if [[ -t 1 && -z ${NO_COLOR:-} ]]; then
    C_RED=$'\e[31m' C_GRN=$'\e[32m' C_YLW=$'\e[33m' C_BLU=$'\e[34m'
    C_BLD=$'\e[1m' C_DIM=$'\e[2m' C_RST=$'\e[0m'
  else
    C_RED="" C_GRN="" C_YLW="" C_BLU="" C_BLD="" C_DIM="" C_RST=""
  fi
}
setup_colors

log_line() {
  (( DRY_RUN )) && return 0
  [[ -n $LOG_FILE ]] || return 0
  printf '%s %s\n' "$(date '+%F %T')" "$*" >>"$LOG_FILE" 2>/dev/null || true
}
info() { printf '%s[INFO]%s %s\n' "$C_BLU" "$C_RST" "$*"; log_line "INFO $*"; }
ok()   { printf '%s[ OK ]%s %s\n' "$C_GRN" "$C_RST" "$*"; log_line "OK   $*"; }
warn() {
  printf '%s[WARN]%s %s\n' "$C_YLW" "$C_RST" "$*" >&2
  log_line "WARN $*"
  [[ -n $STATE_DIR ]] && printf '%s\n' "$*" >>"$STATE_DIR/warnings" 2>/dev/null || true
}
err()  { printf '%s[FAIL]%s %s\n' "$C_RED" "$C_RST" "$*" >&2; log_line "FAIL $*"; }
die()  { err "$1"; exit "${2:-1}"; }
step() { printf '\n%s==> %s%s\n' "$C_BLD" "$*" "$C_RST"; log_line "STEP $*"; }

# ---------------------------------------------------------------------------
# Change primitives: every system change goes through these, so --dry-run
# is guaranteed not to modify the host.
# ---------------------------------------------------------------------------
run() {
  if (( DRY_RUN )); then
    printf '%s[DRY-RUN]%s %s\n' "$C_DIM" "$C_RST" "$(printf '%q ' "$@")"
    return 0
  fi
  log_line "RUN  $(printf '%q ' "$@")"
  local rc=0
  "$@" >>"$LOG_FILE" 2>&1 </dev/null || rc=$?
  if (( rc != 0 )); then
    err "Command failed (exit $rc): $*"
    tail -n 15 "$LOG_FILE" 2>/dev/null | sed 's/^/       /' >&2 || true
  fi
  return "$rc"
}

backup_file() {
  local f=$1 b
  [[ -f $f ]] || return 0
  (( DRY_RUN )) && return 0
  b="$f.vps-sh.$(date +%Y%m%d%H%M%S).bak"
  cp -p "$f" "$b"
  log_line "BACKUP $f -> $b"
}

# write_file PATH MODE CONTENT - atomic write with backup of the old file.
write_file() {
  local path=$1 mode=$2 content=$3 tmp
  if (( DRY_RUN )); then
    printf '%s[DRY-RUN]%s write %s (mode %s)\n' "$C_DIM" "$C_RST" "$path" "$mode"
    # shellcheck disable=SC2001
    sed 's/^/          | /' <<<"$content"
    return 0
  fi
  if [[ -f $path ]] && [[ "$(cat "$path")" == "$content" ]]; then
    log_line "UNCHANGED $path"
    return 0
  fi
  backup_file "$path"
  tmp=$(mktemp "${path}.XXXXXX")
  printf '%s\n' "$content" >"$tmp"
  chmod "$mode" "$tmp"
  mv -f "$tmp" "$path"
  log_line "WROTE $path"
}

append_line_once() {
  local file=$1 line=$2
  if [[ -f $file ]] && grep -qxF -- "$line" "$file"; then return 0; fi
  if (( DRY_RUN )); then
    printf '%s[DRY-RUN]%s append to %s: %s\n' "$C_DIM" "$C_RST" "$file" "$line"
    return 0
  fi
  backup_file "$file"
  printf '%s\n' "$line" >>"$file"
  log_line "APPEND $file: $line"
}

# ---------------------------------------------------------------------------
# Validation helpers (pure; unit-tested)
# ---------------------------------------------------------------------------
valid_username() {
  [[ $1 =~ ^[a-z_][a-z0-9_-]{0,31}$ && $1 != root ]]
}

# Name must be well-formed; when tzdata is installed it must also exist.
# (Minimal images lack tzdata; step_timezone installs it before applying.)
valid_timezone() {
  [[ $1 =~ ^[A-Za-z0-9_+-]+(/[A-Za-z0-9_+-]+)*$ ]] || return 1
  [[ ! -d /usr/share/zoneinfo ]] || [[ -f /usr/share/zoneinfo/$1 ]]
}

valid_pubkey() {
  [[ $1 =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-nistp256@openssh\.com)\ [A-Za-z0-9+/]+=*(\ .*)?$ ]]
}

# size_to_mb "2G" -> 2048. Accepts 256M..64G.
size_to_mb() {
  local s=${1^^} n
  [[ $s =~ ^([0-9]+)([MG])$ ]] || return 1
  n=$((10#${BASH_REMATCH[1]}))
  [[ ${BASH_REMATCH[2]} == G ]] && n=$((n * 1024))
  (( n >= 256 && n <= 65536 )) || return 1
  echo "$n"
}

# normalize_ports "80,443/tcp, 51820/udp" -> "80/tcp 443/tcp 51820/udp"
normalize_ports() {
  local raw=${1// /} item port proto
  local -a items=() out=()
  [[ -z $raw ]] && { echo ""; return 0; }
  IFS=',' read -r -a items <<<"$raw"
  for item in "${items[@]}"; do
    [[ $item =~ ^([0-9]{1,5})(/(tcp|udp))?$ ]] || return 1
    port=$((10#${BASH_REMATCH[1]})) proto=${BASH_REMATCH[3]:-tcp}
    (( port >= 1 && port <= 65535 )) || return 1
    out+=("$port/$proto")
  done
  echo "${out[*]}"
}

# Lines in an authorized_keys file that grant a real login (forced-command
# entries such as cloud images' "Please login as ubuntu" stubs are ignored).
usable_keys() {
  [[ -r $1 ]] || return 0
  grep -E '(ssh-(ed25519|rsa)|ecdsa-sha2-nistp[0-9]+|sk-[a-z0-9@.-]+) AAAA' "$1" | grep -v 'command=' || true
}
has_usable_key() { [[ -n "$(usable_keys "$1")" ]]; }

# ssh_policy ADMIN_READY ROOT_HAS_KEY -> "<PermitRootLogin> <PasswordAuthentication>"
# "keep" means leave the current setting. Password login is only disabled when
# some account can still log in with a key AND reach root.
ssh_policy() {
  local admin_ready=$1 root_has_key=$2
  if (( admin_ready )); then
    echo "no no"
  elif (( root_has_key )); then
    echo "prohibit-password no"
  else
    echo "keep keep"
  fi
}

# ---------------------------------------------------------------------------
# OS detection
# ---------------------------------------------------------------------------
detect_os() {
  [[ -r $OS_RELEASE_FILE ]] || { err "Cannot read $OS_RELEASE_FILE"; return 1; }
  local ID="" ID_LIKE="" VERSION_ID="" PRETTY_NAME="" VERSION_CODENAME="" NAME=""
  # shellcheck disable=SC1090
  source <(grep -E '^(ID|ID_LIKE|VERSION_ID|PRETTY_NAME|VERSION_CODENAME|NAME)=' "$OS_RELEASE_FILE")
  OS_ID=${ID,,}
  OS_LIKE=${ID_LIKE,,}
  OS_VERSION_ID=$VERSION_ID
  OS_MAJOR=${VERSION_ID%%.*}
  OS_NAME=${PRETTY_NAME:-"$NAME $OS_VERSION_ID"}
  OS_CODENAME=$VERSION_CODENAME
  OS_SUPPORTED=0

  case $OS_ID in
    ubuntu|debian) OS_FAMILY=debian ;;
    rhel|rocky|almalinux|centos|fedora) OS_FAMILY=rhel ;;
    *)
      if [[ " $OS_LIKE " == *" debian "* || " $OS_LIKE " == *" ubuntu "* ]]; then OS_FAMILY=debian
      elif [[ " $OS_LIKE " =~ \ (rhel|fedora|centos)\  ]]; then OS_FAMILY=rhel
      else OS_FAMILY=unknown
      fi ;;
  esac

  case $OS_FAMILY in
    debian) PKG_MGR=apt; SUDO_GROUP=sudo ;;
    rhel)   PKG_MGR=dnf; SUDO_GROUP=wheel ;;
    *)      PKG_MGR=""; SUDO_GROUP="" ;;
  esac

  if [[ $OS_MAJOR =~ ^[0-9]+$ ]]; then
    case $OS_ID in
      ubuntu)                 (( OS_MAJOR >= 20 )) && OS_SUPPORTED=1 ;;
      debian)                 (( OS_MAJOR >= 11 )) && OS_SUPPORTED=1 ;;
      rhel|rocky|almalinux)   (( OS_MAJOR >= 8 && OS_MAJOR <= 10 )) && OS_SUPPORTED=1 ;;
      centos)                 (( OS_MAJOR >= 9 )) && OS_SUPPORTED=1 ;;
      fedora)                 (( OS_MAJOR >= 39 )) && OS_SUPPORTED=1 ;;
    esac
  fi
  return 0
}

is_container() {
  if command -v systemd-detect-virt >/dev/null 2>&1 && systemd-detect-virt -cq 2>/dev/null; then return 0; fi
  [[ -f /.dockerenv || -f /run/.containerenv ]]
}
has_systemd() { [[ -d /run/systemd/system ]]; }

sshd_bin() {
  if command -v sshd >/dev/null 2>&1; then command -v sshd
  elif [[ -x /usr/sbin/sshd ]]; then echo /usr/sbin/sshd
  fi
}

# All ports sshd listens on, plus the port of the current SSH session.
detect_ssh_ports() {
  local bin ports=()
  bin=$(sshd_bin)
  if [[ -n $bin ]]; then
    mapfile -t ports < <("$bin" -T 2>/dev/null | awk '$1=="port"{print $2}')
  fi
  if [[ -n ${SSH_CONNECTION:-} ]]; then
    ports+=("$(awk '{print $4}' <<<"$SSH_CONNECTION")")
  fi
  (( ${#ports[@]} )) || ports=(22)
  mapfile -t SSH_PORTS < <(printf '%s\n' "${ports[@]}" | grep -E '^[0-9]+$' | sort -un)
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
check_pass() { printf '  %s[PASS]%s %s\n' "$C_GRN" "$C_RST" "$*"; log_line "PREFLIGHT PASS $*"; }
check_warn() { printf '  %s[WARN]%s %s\n' "$C_YLW" "$C_RST" "$*"; log_line "PREFLIGHT WARN $*"; }
# Soft failures can be overridden with --force; hard ones cannot.
check_fail() {
  local hard=$1; shift
  if (( FORCE )) && [[ $hard != hard ]]; then
    check_warn "$* (overridden by --force)"
  else
    printf '  %s[FAIL]%s %s\n' "$C_RED" "$C_RST" "$*"
    log_line "PREFLIGHT FAIL $*"
    PREFLIGHT_FAILS=$((PREFLIGHT_FAILS + 1))
  fi
}

repo_probe_host() {
  case $OS_ID in
    ubuntu)    echo "archive.ubuntu.com:80" ;;
    debian)    echo "deb.debian.org:443" ;;
    rocky)     echo "mirrors.rockylinux.org:443" ;;
    almalinux) echo "mirrors.almalinux.org:443" ;;
    fedora)    echo "mirrors.fedoraproject.org:443" ;;
    centos)    echo "mirrors.centos.org:443" ;;
    rhel)      echo "cdn.redhat.com:443" ;;
    *)         echo "github.com:443" ;;
  esac
}

preflight() {
  step "Preflight checks"
  PREFLIGHT_FAILS=0

  if (( BASH_VERSINFO[0] >= 4 )); then check_pass "Bash ${BASH_VERSION}"
  else check_fail hard "Bash 4+ required (found ${BASH_VERSION})"; fi

  if (( EUID == 0 )); then check_pass "Running as root"
  elif (( DRY_RUN )); then check_warn "Not root (allowed for --dry-run only)"
  else check_fail hard "Must run as root (try: sudo bash $0 ...)"; fi

  if [[ $OS_FAMILY == unknown ]]; then
    check_fail hard "Unsupported OS: $OS_NAME (need Debian/Ubuntu or RHEL-family)"
  elif (( OS_SUPPORTED )); then
    check_pass "OS: $OS_NAME (family: $OS_FAMILY, pkg: $PKG_MGR)"
  else
    check_fail soft "OS version not tested: $OS_NAME"
  fi

  case $(uname -m) in
    x86_64|aarch64) check_pass "Architecture: $(uname -m)" ;;
    *) check_warn "Architecture $(uname -m) untested" ;;
  esac

  if has_systemd; then check_pass "systemd is running"
  else check_fail soft "systemd not running (container?) - services cannot be managed"; fi

  local free_mb
  free_mb=$(df -Pm / | awk 'NR==2{print $4}')
  if (( free_mb < 1024 )); then check_fail soft "Low disk space on /: ${free_mb} MB free (need 1024+)"
  elif (( free_mb < 3072 )); then check_warn "Disk space on /: ${free_mb} MB free"
  else check_pass "Disk space on /: ${free_mb} MB free"; fi

  local mem_mb
  mem_mb=$(awk '/^MemTotal:/{print int($2/1024)}' /proc/meminfo)
  if (( mem_mb < 512 )); then check_warn "Memory: ${mem_mb} MB (very low)"
  else check_pass "Memory: ${mem_mb} MB"; fi

  local probe host port
  probe=$(repo_probe_host); host=${probe%:*}; port=${probe##*:}
  if ! getent hosts "$host" >/dev/null 2>&1; then
    check_fail soft "DNS lookup failed for $host"
  elif timeout 5 bash -c "exec 3<>/dev/tcp/$host/$port" 2>/dev/null; then
    check_pass "Network: reached $host:$port"
  else
    check_fail soft "Cannot reach package mirror $host:$port"
  fi

  if pgrep -x 'apt|apt-get|dpkg|unattended-upgr|dnf|yum|packagekitd' >/dev/null 2>&1; then
    check_warn "Another package manager process is running; installer will wait for its lock"
  else
    check_pass "No package manager running"
  fi

  if [[ -n $(sshd_bin) ]]; then check_pass "sshd found; SSH port(s): ${SSH_PORTS[*]}"
  else check_warn "sshd not found; SSH hardening will be skipped"; fi

  if [[ -n ${SSH_CONNECTION:-} ]]; then
    check_warn "Running over SSH from ${SSH_CONNECTION%% *}: keep this session open until you verify a new login"
  fi

  if is_container; then check_warn "Container detected: swap and some services will be skipped"; fi

  if (( PREFLIGHT_FAILS > 0 )); then
    if (( DRY_RUN )); then
      warn "$PREFLIGHT_FAILS preflight check(s) failed; a real run would stop here. Continuing dry-run."
    else
      die "$PREFLIGHT_FAILS preflight check(s) failed. Fix them or use --force for soft failures." 3
    fi
  fi
}

# ---------------------------------------------------------------------------
# Package / service abstraction
# ---------------------------------------------------------------------------
APT_OPTS=(-y -o DPkg::Lock::Timeout=300 -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

pkg_refresh() {
  case $PKG_MGR in
    apt) run env DEBIAN_FRONTEND=noninteractive apt-get "${APT_OPTS[@]}" update ;;
    dnf) run dnf -y makecache ;;
  esac
}
pkg_upgrade() {
  case $PKG_MGR in
    apt) run env DEBIAN_FRONTEND=noninteractive apt-get "${APT_OPTS[@]}" upgrade ;;
    dnf) run dnf -y upgrade ;;
  esac
}
pkg_install() {
  (( $# )) || return 0
  case $PKG_MGR in
    apt) run env DEBIAN_FRONTEND=noninteractive apt-get "${APT_OPTS[@]}" install "$@" ;;
    dnf) run dnf -y install "$@" ;;
  esac
}
pkg_installed() {
  case $PKG_MGR in
    apt) dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'install ok installed' ;;
    dnf) rpm -q "$1" >/dev/null 2>&1 ;;
  esac
}

svc_enable_now() {
  if ! has_systemd; then warn "No systemd: not enabling $1"; return 0; fi
  run systemctl enable --now "$1"
}
svc_restart() {
  has_systemd || return 0
  run systemctl restart "$1"
}

# EPEL provides fail2ban/htop on RHEL clones (Fedora does not need it).
ensure_epel() {
  [[ $OS_FAMILY == rhel && $OS_ID != fedora ]] || return 0
  pkg_installed epel-release && return 0
  if [[ $OS_ID == rhel ]]; then
    pkg_install "https://dl.fedoraproject.org/pub/epel/epel-release-latest-${OS_MAJOR}.noarch.rpm"
  else
    pkg_install epel-release
  fi
}

# ---------------------------------------------------------------------------
# Steps (each runs in a subshell with `set -e`; any failure fails the step)
# ---------------------------------------------------------------------------
step_upgrade() {
  pkg_refresh
  pkg_upgrade
  ok "System packages upgraded"
}

step_base() {
  local pkgs
  if [[ $OS_FAMILY == debian ]]; then
    pkgs=(ca-certificates curl wget git vim htop unzip jq gnupg tmux rsync logrotate sudo)
    pkg_installed chrony || pkg_installed systemd-timesyncd || pkgs+=(systemd-timesyncd)
  else
    ensure_epel
    pkgs=(ca-certificates wget git vim-enhanced htop unzip jq gnupg2 tmux rsync logrotate tar sudo)
    command -v curl >/dev/null 2>&1 || pkgs+=(curl)   # avoid curl-minimal conflict
    pkg_installed chrony || pkgs+=(chrony)
  fi
  (( DO_UPGRADE )) || pkg_refresh
  pkg_install "${pkgs[@]}"
  if has_systemd && ! is_container; then
    run timedatectl set-ntp true || warn "Could not enable NTP time sync"
  fi
  ok "Base packages installed"
}

step_timezone() {
  [[ -d /usr/share/zoneinfo ]] || pkg_install tzdata
  if (( ! DRY_RUN )) && [[ ! -f /usr/share/zoneinfo/$TIMEZONE ]]; then
    err "Unknown timezone: $TIMEZONE"; return 1
  fi
  if has_systemd; then
    run timedatectl set-timezone "$TIMEZONE"
  else
    run ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
  fi
  ok "Timezone set to $TIMEZONE"
}

admin_home() {
  local h
  h=$(getent passwd "$ADMIN_USER" | cut -d: -f6) || true
  echo "${h:-/home/$ADMIN_USER}"
}

password_set() {
  local hash
  hash=$(getent shadow "$1" 2>/dev/null | cut -d: -f2) || true
  [[ -n $hash && $hash != '!'* && $hash != '*'* ]]
}

step_admin_user() {
  local home keys line
  command -v sudo >/dev/null 2>&1 || pkg_install sudo

  if id "$ADMIN_USER" >/dev/null 2>&1; then
    info "User $ADMIN_USER exists; ensuring membership of $SUDO_GROUP"
    run usermod -aG "$SUDO_GROUP" "$ADMIN_USER"
  else
    run useradd -m -s /bin/bash -G "$SUDO_GROUP" "$ADMIN_USER"
  fi
  home=$(admin_home)

  keys=$SSH_PUBKEYS
  if (( COPY_ROOT_KEYS )); then
    keys+=$'\n'"$(usable_keys /root/.ssh/authorized_keys)"
  fi
  if [[ -n ${keys//[$'\n' ]/} ]]; then
    run install -d -m 700 -o "$ADMIN_USER" -g "$ADMIN_USER" "$home/.ssh"
    if (( ! DRY_RUN )) && [[ ! -f $home/.ssh/authorized_keys ]]; then
      install -m 600 -o "$ADMIN_USER" -g "$ADMIN_USER" /dev/null "$home/.ssh/authorized_keys"
    fi
    while IFS= read -r line; do
      [[ -n $line ]] && append_line_once "$home/.ssh/authorized_keys" "$line"
    done <<<"$keys"
    run chown "$ADMIN_USER:$ADMIN_USER" "$home/.ssh/authorized_keys"
    run chmod 600 "$home/.ssh/authorized_keys"
  fi

  if (( SUDO_NOPASSWD )); then
    local f="/etc/sudoers.d/90-vps-sh-$ADMIN_USER"
    write_file "$f" 0440 "# $MANAGED_TAG
$ADMIN_USER ALL=(ALL) NOPASSWD:ALL"
    if (( ! DRY_RUN )) && ! visudo -cf "$f" >/dev/null; then
      rm -f "$f"; err "sudoers validation failed; removed $f"; return 1
    fi
  elif ! password_set "$ADMIN_USER" && (( ! DRY_RUN )); then
    if [[ $MODE == interactive ]]; then
      info "Set a password for $ADMIN_USER (needed for sudo):"
      passwd "$ADMIN_USER" </dev/tty || warn "Password not set for $ADMIN_USER; sudo will not work"
    else
      warn "$ADMIN_USER has no password: sudo will not work until you run 'passwd $ADMIN_USER' (or use --sudo-nopasswd)"
    fi
  fi
  ok "Admin user $ADMIN_USER configured"
}

step_firewall() {
  local p
  if [[ $OS_FAMILY == debian ]]; then
    pkg_installed ufw || pkg_install ufw
    # Rules are added before enabling so the SSH session is never cut off.
    for p in "${SSH_PORTS[@]}"; do run ufw allow "$p/tcp" comment 'SSH (vps.sh)'; done
    for p in $OPEN_PORTS; do run ufw allow "$p" comment 'vps.sh'; done
    if ufw status 2>/dev/null | grep -q 'Status: active'; then
      info "ufw already active; existing policy kept, rules added"
    else
      run ufw default deny incoming
      run ufw default allow outgoing
      run ufw --force enable
    fi
  else
    pkg_installed firewalld || pkg_install firewalld
    if has_systemd && systemctl is-active --quiet firewalld; then
      for p in "${SSH_PORTS[@]}"; do run firewall-cmd --permanent --add-port="$p/tcp"; done
      for p in $OPEN_PORTS; do run firewall-cmd --permanent --add-port="$p"; done
      run firewall-cmd --reload
    else
      for p in "${SSH_PORTS[@]}"; do run firewall-offline-cmd --add-port="$p/tcp"; done
      for p in $OPEN_PORTS; do run firewall-offline-cmd --add-port="$p"; done
      svc_enable_now firewalld
    fi
  fi
  ok "Firewall active: SSH ${SSH_PORTS[*]}${OPEN_PORTS:+, plus $OPEN_PORTS}"
}

step_fail2ban() {
  local ports
  ports=$(IFS=,; echo "${SSH_PORTS[*]}")
  ensure_epel
  pkg_install fail2ban python3-systemd
  write_file /etc/fail2ban/jail.d/vps-sh.local 0644 "# $MANAGED_TAG
[sshd]
enabled  = true
port     = $ports
backend  = systemd
maxretry = 5
findtime = 10m
bantime  = 1h"
  svc_enable_now fail2ban
  svc_restart fail2ban
  ok "fail2ban protecting sshd on port(s) $ports"
}

step_auto_updates() {
  if [[ $OS_FAMILY == debian ]]; then
    pkg_install unattended-upgrades
    write_file /etc/apt/apt.conf.d/20auto-upgrades 0644 'APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";'
    write_file /etc/apt/apt.conf.d/52vps-sh-unattended 0644 "// $MANAGED_TAG
Unattended-Upgrade::Automatic-Reboot \"false\";"
    ok "Automatic security updates enabled (no auto-reboot)"
  else
    pkg_install dnf-automatic || pkg_install dnf5-plugin-automatic
    local conf=/etc/dnf/automatic.conf
    if [[ -f $conf ]]; then
      backup_file "$conf"
      run sed -i -E 's/^#?\s*upgrade_type\s*=.*/upgrade_type = security/; s/^#?\s*apply_updates\s*=.*/apply_updates = yes/' "$conf"
    else
      write_file "$conf" 0644 "# $MANAGED_TAG
[commands]
upgrade_type = security
apply_updates = yes
reboot = never"
    fi
    if has_systemd; then
      if systemctl list-unit-files dnf-automatic.timer 2>/dev/null | grep -q '^dnf-automatic.timer'; then
        svc_enable_now dnf-automatic.timer
      else
        svc_enable_now dnf5-automatic.timer
      fi
    fi
    ok "Automatic security updates enabled via dnf-automatic (no auto-reboot)"
  fi
}

step_swap() {
  local mb free_mb
  if [[ -n "$(swapon --show --noheadings 2>/dev/null)" ]]; then info "Swap already active; skipping"; return 0; fi
  if is_container; then warn "Container: skipping swap"; return 0; fi
  if [[ -e /swapfile ]]; then warn "/swapfile exists but is not active; leaving it alone"; return 0; fi
  if [[ "$(findmnt -no FSTYPE / 2>/dev/null)" == btrfs ]]; then warn "btrfs root: skipping swap file"; return 0; fi
  mb=$(size_to_mb "$SWAP_SIZE")
  free_mb=$(df -Pm / | awk 'NR==2{print $4}')
  if (( free_mb < mb + 1024 )); then warn "Not enough disk for ${SWAP_SIZE} swap; skipping"; return 0; fi

  run fallocate -l "${mb}M" /swapfile || run dd if=/dev/zero of=/swapfile bs=1M count="$mb" status=none
  run chmod 600 /swapfile
  run mkswap /swapfile
  run swapon /swapfile
  append_line_once /etc/fstab "/swapfile none swap sw 0 0"
  write_file /etc/sysctl.d/99-vps-sh.conf 0644 "# $MANAGED_TAG
vm.swappiness = 10"
  run sysctl -p /etc/sysctl.d/99-vps-sh.conf
  ok "Swap file of $SWAP_SIZE created"
}

step_docker() {
  if command -v docker >/dev/null 2>&1; then info "Docker already installed; skipping"; return 0; fi
  if [[ $OS_FAMILY == debian ]]; then
    local arch
    arch=$(dpkg --print-architecture)
    pkg_install ca-certificates curl
    run install -m 0755 -d /etc/apt/keyrings
    run curl -fsSL "https://download.docker.com/linux/$OS_ID/gpg" -o /etc/apt/keyrings/docker.asc
    run chmod a+r /etc/apt/keyrings/docker.asc
    write_file /etc/apt/sources.list.d/docker.list 0644 \
      "deb [arch=$arch signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/$OS_ID $OS_CODENAME stable"
    pkg_refresh
  else
    local repo=centos
    [[ $OS_ID == fedora ]] && repo=fedora
    [[ $OS_ID == rhel ]] && repo=rhel
    pkg_install dnf-plugins-core
    run dnf config-manager --add-repo "https://download.docker.com/linux/$repo/docker-ce.repo" \
      || run dnf config-manager addrepo --from-repofile="https://download.docker.com/linux/$repo/docker-ce.repo"
  fi
  pkg_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  svc_enable_now docker
  (( DO_FIREWALL )) && warn "Docker-published ports bypass ufw/firewalld rules; bind to 127.0.0.1 unless public"
  ok "Docker Engine installed"
}

# Sets ADMIN_READY / ROOT_HAS_KEY from the real system (or the plan, in dry-run).
assess_key_access() {
  ADMIN_READY=0 ROOT_HAS_KEY=0
  has_usable_key /root/.ssh/authorized_keys && ROOT_HAS_KEY=1
  [[ -n $ADMIN_USER ]] || return 0

  local has_key=0 sudo_ok=0 in_group=0
  if id "$ADMIN_USER" >/dev/null 2>&1; then
    has_usable_key "$(admin_home)/.ssh/authorized_keys" && has_key=1
    id -nG "$ADMIN_USER" | tr ' ' '\n' | grep -qx "$SUDO_GROUP" && in_group=1
    if [[ -f /etc/sudoers.d/90-vps-sh-$ADMIN_USER ]] || password_set "$ADMIN_USER"; then sudo_ok=1; fi
  fi
  if (( DRY_RUN )); then   # account for what this run would do
    [[ -n $SSH_PUBKEYS ]] && has_key=1
    (( COPY_ROOT_KEYS && ROOT_HAS_KEY )) && has_key=1
    in_group=1
    (( SUDO_NOPASSWD )) && sudo_ok=1
    [[ $MODE == interactive ]] && sudo_ok=1
  fi
  (( has_key && in_group && sudo_ok )) && ADMIN_READY=1
  return 0
}

ssh_service() {
  local s
  for s in ssh sshd; do
    if systemctl list-unit-files "$s.service" 2>/dev/null | grep -q "^$s.service"; then echo "$s"; return 0; fi
  done
  echo sshd
}

step_ssh_harden() {
  local bin conf=/etc/ssh/sshd_config dropin=/etc/ssh/sshd_config.d/01-vps-sh-hardening.conf
  local policy prl pa body
  bin=$(sshd_bin)
  [[ -n $bin ]] || { warn "sshd not installed; skipping SSH hardening"; return 0; }
  if ! grep -Eiq '^\s*Include\s+/etc/ssh/sshd_config\.d/\*\.conf' "$conf"; then
    warn "$conf has no 'Include /etc/ssh/sshd_config.d/*.conf'; skipping hardening (main config left untouched)"
    return 0
  fi

  assess_key_access
  policy=$(ssh_policy "$ADMIN_READY" "$ROOT_HAS_KEY")
  prl=${policy% *} pa=${policy#* }
  if [[ $pa == keep ]]; then
    warn "No working SSH key login found: password login and root login left unchanged"
  fi

  # Lexically-first drop-in wins in sshd, so 01- beats cloud-init's 50-*.conf.
  body="# $MANAGED_TAG - delete this file and reload sshd to revert.
PubkeyAuthentication yes
PermitEmptyPasswords no
MaxAuthTries 5
LoginGraceTime 30
X11Forwarding no"
  [[ $pa == no ]] && body+=$'\nPasswordAuthentication no\nChallengeResponseAuthentication no'
  [[ $prl != keep ]] && body+=$'\nPermitRootLogin '"$prl"

  write_file "$dropin" 0644 "$body"
  if (( DRY_RUN )); then
    info "Would validate with 'sshd -t' and reload; PermitRootLogin=$prl PasswordAuthentication=$pa"
    return 0
  fi
  if ! "$bin" -t >>"$LOG_FILE" 2>&1; then
    rm -f "$dropin"
    err "sshd -t rejected the new config; removed $dropin (sshd untouched)"
    return 1
  fi
  if has_systemd; then run systemctl reload "$(ssh_service)"; fi

  if [[ $pa == no ]] && ! "$bin" -T 2>/dev/null | grep -qx 'passwordauthentication no'; then
    warn "PasswordAuthentication is still enabled by an earlier directive in $conf; review it manually"
  fi
  ok "SSH hardened (PermitRootLogin=$prl, PasswordAuthentication=$pa)"
}

# ---------------------------------------------------------------------------
# User choices
# ---------------------------------------------------------------------------
tty_available() { { : </dev/tty; } 2>/dev/null; }

ask_yn() {
  local prompt=$1 default=$2 ans hint="[y/N]"
  [[ $default == y ]] && hint="[Y/n]"
  while true; do
    read -r -p "  $prompt $hint " ans </dev/tty || ans=""
    ans=${ans:-$default}
    case ${ans,,} in
      y|yes) return 0 ;;
      n|no)  return 1 ;;
    esac
  done
}

ask_value() {
  local prompt=$1 default=$2 ans
  read -r -p "  $prompt${default:+ [$default]}: " ans </dev/tty || ans=""
  echo "${ans:-$default}"
}

yn() { (( $1 )) && echo y || echo n; }

choose_components() {
  local v
  step "Choose components (Enter accepts the default)"
  ask_yn "Upgrade all installed packages now?" "$(yn $DO_UPGRADE)" && DO_UPGRADE=1 || DO_UPGRADE=0
  ask_yn "Install base tools (curl git vim htop jq tmux ...)?" "$(yn $DO_BASE)" && DO_BASE=1 || DO_BASE=0
  ask_yn "Enable automatic security updates (no auto-reboot)?" "$(yn $DO_AUTO_UPDATES)" && DO_AUTO_UPDATES=1 || DO_AUTO_UPDATES=0
  if ask_yn "Enable firewall, allowing SSH port(s) ${SSH_PORTS[*]}?" "$(yn $DO_FIREWALL)"; then
    DO_FIREWALL=1
    while true; do
      v=$(ask_value "Extra ports to open, e.g. 80,443 or 51820/udp (blank = none)" "${OPEN_PORTS// /,}")
      if OPEN_PORTS=$(normalize_ports "$v"); then break; fi
      echo "  Invalid port list."
    done
  else DO_FIREWALL=0; fi
  ask_yn "Install fail2ban to block SSH brute force?" "$(yn $DO_FAIL2BAN)" && DO_FAIL2BAN=1 || DO_FAIL2BAN=0
  if [[ -z "$(swapon --show --noheadings 2>/dev/null)" ]]; then
    if ask_yn "No swap found. Create a swap file?" "$(yn $DO_SWAP)"; then
      DO_SWAP=1
      while true; do
        v=$(ask_value "Swap size (256M-64G)" "$SWAP_SIZE")
        size_to_mb "$v" >/dev/null && { SWAP_SIZE=$v; break; }
        echo "  Invalid size."
      done
    else DO_SWAP=0; fi
  fi

  while true; do
    v=$(ask_value "Admin (sudo) username to create/configure (blank = skip)" "$ADMIN_USER")
    [[ -z $v ]] || valid_username "$v" && { ADMIN_USER=$v; break; }
    echo "  Invalid username (lowercase letters, digits, _ and -; not root)."
  done
  if [[ -n $ADMIN_USER ]]; then
    if has_usable_key /root/.ssh/authorized_keys; then
      ask_yn "Copy root's authorized SSH keys to $ADMIN_USER?" y && COPY_ROOT_KEYS=1 || COPY_ROOT_KEYS=0
    fi
    while true; do
      v=$(ask_value "Paste a public SSH key for $ADMIN_USER (blank = none)" "")
      [[ -z $v ]] && break
      if valid_pubkey "$v"; then SSH_PUBKEYS+=${SSH_PUBKEYS:+$'\n'}$v; break; fi
      echo "  That does not look like an OpenSSH public key."
    done
    ask_yn "Allow $ADMIN_USER to sudo without a password?" "$(yn $SUDO_NOPASSWD)" && SUDO_NOPASSWD=1 || SUDO_NOPASSWD=0
  fi
  ask_yn "Harden SSH (key-only login only if a working key exists)?" "$(yn $DO_SSH_HARDEN)" && DO_SSH_HARDEN=1 || DO_SSH_HARDEN=0

  while true; do
    v=$(ask_value "Timezone, e.g. UTC or Europe/Berlin (blank = keep current)" "$TIMEZONE")
    [[ -z $v ]] || valid_timezone "$v" && { TIMEZONE=$v; break; }
    echo "  Unknown timezone."
  done
  ask_yn "Install Docker Engine + Compose plugin?" "$(yn $DO_DOCKER)" && DO_DOCKER=1 || DO_DOCKER=0
}

onoff() { (( $1 )) && printf '%sYES%s' "$C_GRN" "$C_RST" || printf '%sno%s' "$C_DIM" "$C_RST"; }

show_plan() {
  step "Plan"
  printf '  %-28s %s\n' \
    "Mode" "$MODE$( (( DRY_RUN )) && echo ' (dry-run: no changes)')" \
    "OS" "$OS_NAME" \
    "Upgrade packages" "$(onoff $DO_UPGRADE)" \
    "Base tools" "$(onoff $DO_BASE)" \
    "Auto security updates" "$(onoff $DO_AUTO_UPDATES)" \
    "Firewall" "$(onoff $DO_FIREWALL) (SSH ${SSH_PORTS[*]}${OPEN_PORTS:+; $OPEN_PORTS})" \
    "fail2ban" "$(onoff $DO_FAIL2BAN)" \
    "Swap file" "$(onoff $DO_SWAP) ($SWAP_SIZE, only if no swap)" \
    "Admin user" "${ADMIN_USER:-none}" \
    "SSH hardening" "$(onoff $DO_SSH_HARDEN)" \
    "Timezone" "${TIMEZONE:-unchanged}" \
    "Docker" "$(onoff $DO_DOCKER)"
  echo
}

# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------
usage() {
  cat <<EOF
vps.sh $VPS_SH_VERSION - production-safe VPS bootstrap installer

Usage: sudo bash vps.sh [options]

Modes:
  (default)               Interactive: choose components, confirm before changes
  -y, --yes, --unattended Unattended: no prompts, flags + safe defaults
  -n, --dry-run           Show every change without making it (any mode)

Components (default on unless noted):
      --no-upgrade        Skip upgrading installed packages
      --no-base           Skip base tools
      --no-auto-updates   Skip automatic security updates
      --no-firewall       Skip ufw/firewalld
      --no-fail2ban       Skip fail2ban
      --no-swap           Skip swap file creation
      --no-ssh-hardening  Skip SSH hardening
      --with-docker       Install Docker Engine (default off)

Settings:
      --admin-user NAME   Create/configure a sudo user
      --ssh-key KEY|FILE  Public key (or file of keys) for the admin user
      --copy-root-keys    Copy root's authorized_keys to the admin user
      --sudo-nopasswd     Passwordless sudo for the admin user (default off)
      --open-ports LIST   Extra firewall ports, e.g. 80,443,51820/udp
      --swap-size SIZE    Swap file size, 256M-64G (default $SWAP_SIZE)
      --timezone TZ       e.g. UTC, Europe/Berlin (default: unchanged)
      --log-file PATH     Log path (default $LOG_FILE)
  -f, --force             Continue past soft preflight failures
  -h, --help              Show this help
  -V, --version           Show version

Examples:
  sudo bash vps.sh                                  # interactive
  sudo bash vps.sh --dry-run --yes                  # preview defaults
  sudo bash vps.sh --yes --admin-user deploy --copy-root-keys --open-ports 80,443
EOF
}

need_arg() { [[ $# -ge 2 && -n $2 && $2 != -* ]] || die "Option $1 requires a value" 2; }

parse_args() {
  local line
  while (( $# )); do
    case $1 in
      -y|--yes|--unattended) MODE=unattended ;;
      -n|--dry-run)          DRY_RUN=1 ;;
      -f|--force)            FORCE=1 ;;
      --no-upgrade)          DO_UPGRADE=0 ;;
      --no-base)             DO_BASE=0 ;;
      --no-auto-updates)     DO_AUTO_UPDATES=0 ;;
      --no-firewall)         DO_FIREWALL=0 ;;
      --no-fail2ban)         DO_FAIL2BAN=0 ;;
      --no-swap)             DO_SWAP=0 ;;
      --no-ssh-hardening)    DO_SSH_HARDEN=0 ;;
      --with-docker)         DO_DOCKER=1 ;;
      --copy-root-keys)      COPY_ROOT_KEYS=1 ;;
      --sudo-nopasswd)       SUDO_NOPASSWD=1 ;;
      --admin-user)
        need_arg "$@"; valid_username "$2" || die "Invalid username: $2" 2
        ADMIN_USER=$2; shift ;;
      --ssh-key)
        [[ $# -ge 2 && -n $2 ]] || die "Option $1 requires a value" 2
        if [[ -f $2 ]]; then
          while IFS= read -r line || [[ -n $line ]]; do
            [[ -z $line || $line == \#* ]] && continue
            valid_pubkey "$line" || die "Invalid public key in $2: ${line:0:40}..." 2
            SSH_PUBKEYS+=${SSH_PUBKEYS:+$'\n'}$line
          done <"$2"
        else
          valid_pubkey "$2" || die "Invalid public key (expected e.g. 'ssh-ed25519 AAAA...')" 2
          SSH_PUBKEYS+=${SSH_PUBKEYS:+$'\n'}$2
        fi
        shift ;;
      --open-ports)
        need_arg "$@"; OPEN_PORTS=$(normalize_ports "$2") || die "Invalid port list: $2" 2; shift ;;
      --swap-size)
        need_arg "$@"; size_to_mb "$2" >/dev/null || die "Invalid swap size: $2 (256M-64G)" 2
        SWAP_SIZE=$2; shift ;;
      --timezone)
        need_arg "$@"; valid_timezone "$2" || die "Unknown timezone: $2" 2
        TIMEZONE=$2; shift ;;
      --log-file)
        need_arg "$@"; LOG_FILE=$2; shift ;;
      -h|--help)    usage; exit 0 ;;
      -V|--version) echo "vps.sh $VPS_SH_VERSION"; exit 0 ;;
      *) usage >&2; die "Unknown option: $1" 2 ;;
    esac
    shift
  done
  if [[ -n $SSH_PUBKEYS || $COPY_ROOT_KEYS == 1 || $SUDO_NOPASSWD == 1 ]] && [[ -z $ADMIN_USER && $MODE == unattended ]]; then
    die "--ssh-key, --copy-root-keys and --sudo-nopasswd require --admin-user" 2
  fi
}

# ---------------------------------------------------------------------------
# Orchestration
# ---------------------------------------------------------------------------
# Runs a step in a subshell with errexit active, so any failing command fails
# the step without aborting the remaining steps.
run_step() {
  local name=$1 fn=$2 rc=0
  step "$name"
  set +e
  ( set -e; "$fn" )
  rc=$?
  set -e
  if (( rc == 0 )); then STEP_RESULTS+=("OK      $name")
  else STEP_RESULTS+=("FAILED  $name"); err "Step '$name' failed (exit $rc)"; fi
  return 0
}

acquire_lock() {
  (( DRY_RUN )) && return 0
  mkdir -p "$(dirname "$LOCK_FILE")"
  exec 9>"$LOCK_FILE"
  flock -n 9 || die "Another vps.sh run is in progress ($LOCK_FILE)" 1
}

init_log() {
  (( DRY_RUN )) && return 0
  mkdir -p "$(dirname "$LOG_FILE")"
  touch "$LOG_FILE" && chmod 600 "$LOG_FILE"
  log_line "===== vps.sh $VPS_SH_VERSION start (mode=$MODE) on $OS_NAME ====="
}

reboot_required() {
  [[ -f /var/run/reboot-required ]] && return 0
  if command -v needs-restarting >/dev/null 2>&1; then
    needs-restarting -r >/dev/null 2>&1 || return 0
  fi
  return 1
}

summary() {
  local r failed=0
  step "Summary"
  for r in "${STEP_RESULTS[@]}"; do
    if [[ $r == FAILED* ]]; then failed=1; printf '  %s%s%s\n' "$C_RED" "$r" "$C_RST"
    else printf '  %s%s%s\n' "$C_GRN" "$r" "$C_RST"; fi
  done
  if [[ -s $STATE_DIR/warnings ]]; then
    echo; echo "  Warnings:"
    sort -u "$STATE_DIR/warnings" | sed 's/^/    - /'
  fi
  echo
  if (( DRY_RUN )); then
    info "Dry-run complete. Nothing was changed."
  else
    info "Log: $LOG_FILE (config backups: *.vps-sh.<timestamp>.bak)"
    if reboot_required; then warn "A reboot is required to finish updates. Reboot when convenient: sudo reboot"; fi
    if (( DO_SSH_HARDEN )) && [[ -n $ADMIN_USER ]]; then
      printf '\n  %sIMPORTANT:%s before closing this session, test in a NEW terminal:\n    ssh -p %s %s@<server-ip>\n' \
        "$C_BLD" "$C_RST" "${SSH_PORTS[0]}" "$ADMIN_USER"
    fi
  fi
  return "$failed"
}

main() {
  parse_args "$@"
  STATE_DIR=$(mktemp -d)
  trap 'rm -rf "$STATE_DIR"' EXIT

  printf '%svps.sh %s%s - VPS bootstrap installer%s\n' "$C_BLD" "$VPS_SH_VERSION" "$C_RST" \
    "$( (( DRY_RUN )) && echo ' [DRY-RUN]')"

  detect_os || die "OS detection failed" 3
  detect_ssh_ports
  preflight

  if [[ $MODE == interactive ]]; then
    tty_available || die "No terminal for prompts. Use --yes for unattended mode." 2
    choose_components
    show_plan
    if ! ask_yn "Apply this plan$( (( DRY_RUN )) && echo ' (dry-run)')?" n; then
      info "Aborted by user. Nothing was changed."; exit 0
    fi
  else
    show_plan
  fi

  acquire_lock
  init_log

  (( DO_UPGRADE ))      && run_step "Upgrade packages" step_upgrade
  (( DO_BASE ))         && run_step "Base tools" step_base
  [[ -n $TIMEZONE ]]    && run_step "Timezone" step_timezone
  [[ -n $ADMIN_USER ]]  && run_step "Admin user" step_admin_user
  (( DO_FIREWALL ))     && run_step "Firewall" step_firewall
  (( DO_FAIL2BAN ))     && run_step "fail2ban" step_fail2ban
  (( DO_AUTO_UPDATES )) && run_step "Automatic security updates" step_auto_updates
  (( DO_SWAP ))         && run_step "Swap" step_swap
  (( DO_DOCKER ))       && run_step "Docker" step_docker
  # SSH last: it depends on the admin user and keys being in place.
  if (( DO_SSH_HARDEN )); then
    if printf '%s\n' "${STEP_RESULTS[@]}" | grep -q '^FAILED  Admin user'; then
      STEP_RESULTS+=("SKIPPED SSH hardening (admin user step failed)")
    else
      run_step "SSH hardening" step_ssh_harden
    fi
  fi

  summary || exit 1
}

if [[ ${BASH_SOURCE[0]:-$0} == "$0" ]]; then
  main "$@"
fi
