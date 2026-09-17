#!/usr/bin/env bash
# Host hardening verification - run on the droplet after cloud-init.
# Usage: sudo /opt/oxytrip/provision/verify-host.sh
# Exits non-zero if any check fails.

set -euo pipefail

# PIPEFAIL RULE for this script: never pipe a command into a reader that can stop
# early (awk ...exit, grep -q, head). The writer then dies of SIGPIPE (exit 141),
# pipefail reports failure, and set -e aborts the script or flips a check's result.
# Capture the output into a variable first, then parse it with a here-string.

PASS=0
FAIL=0

pass() {
  printf 'PASS  %s\n' "$1"
  PASS=$((PASS + 1))
}

fail() {
  printf 'FAIL  %s\n' "$1"
  FAIL=$((FAIL + 1))
}

need_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "Run as root (sudo $0)" >&2
    exit 1
  fi
}

sshd_effective() {
  # Prefer sshd -T (effective config); fall back to grepping fragments.
  if command -v sshd >/dev/null 2>&1; then
    local cfg
    cfg="$(sshd -T 2>/dev/null || true)"
    awk -v k="$1" 'tolower($1)==tolower(k) {print tolower($2); exit}' <<<"${cfg}"
  fi
}

need_root

# --- SSH ---
root_login="$(sshd_effective permitrootlogin || true)"
if [[ "${root_login}" == "no" || "${root_login}" == "prohibit-password" || "${root_login}" == "without-password" ]]; then
  # prohibit/without-password still allow key-based root; we require full disable.
  if [[ "${root_login}" == "no" ]]; then
    pass "root SSH login disabled (PermitRootLogin no)"
  else
    fail "root SSH login not fully disabled (PermitRootLogin=${root_login})"
  fi
else
  fail "root SSH login not disabled (PermitRootLogin=${root_login:-unknown})"
fi

pw_auth="$(sshd_effective passwordauthentication || true)"
if [[ "${pw_auth}" == "no" ]]; then
  pass "password authentication disabled"
else
  fail "password authentication still enabled (PasswordAuthentication=${pw_auth:-unknown})"
fi

# --- deploy user ---
if id -u deploy >/dev/null 2>&1; then
  pass "deploy user exists"
else
  fail "deploy user missing"
fi

deploy_groups="$(id -nG deploy 2>/dev/null || true)"
if grep -qx docker <<<"$(tr ' ' '\n' <<<"${deploy_groups}")"; then
  pass "deploy is in the docker group"
else
  fail "deploy is not in the docker group"
fi

# --- UFW ---
ufw_out="$(ufw status 2>/dev/null || true)"
if grep -qi 'Status: active' <<<"${ufw_out}"; then
  pass "ufw is active"
else
  fail "ufw is not active"
fi

mapfile -t allowed < <(echo "${ufw_out}" | grep -E 'ALLOW' | grep -oE '[0-9]+/tcp' | cut -d/ -f1 | sort -nu)

expected=(22 80 443)
# Exactly these three (and no extras that are ALLOW IN)
extra=0
missing=0
allowed_list="$(printf '%s\n' "${allowed[@]:-}")"
expected_list="$(printf '%s\n' "${expected[@]}")"
for p in "${expected[@]}"; do
  if ! grep -qx "$p" <<<"${allowed_list}"; then
    missing=1
  fi
done
for p in "${allowed[@]:-}"; do
  if ! grep -qx "$p" <<<"${expected_list}"; then
    extra=1
  fi
done

if [[ "${missing}" -eq 0 && "${extra}" -eq 0 && "${#allowed[@]}" -eq 3 ]]; then
  pass "ufw allows exactly 22/80/443"
else
  fail "ufw allow set is not exactly 22/80/443 (saw: ${allowed[*]:-none})"
fi

# --- unattended-upgrades ---
dpkg_uu="$(dpkg -l unattended-upgrades 2>/dev/null || true)"
if grep -q '^ii' <<<"${dpkg_uu}"; then
  pass "unattended-upgrades package installed"
else
  fail "unattended-upgrades package missing"
fi

apt_dump="$(apt-config dump 2>/dev/null || true)"
# Accept APT::Periodic::Unattended-Upgrade "1"
periodic="$(awk -F'"' '/APT::Periodic::Unattended-Upgrade /{print $2; exit}' <<<"${apt_dump}")"
if [[ "${periodic}" == "1" ]] || systemctl is-enabled unattended-upgrades >/dev/null 2>&1; then
  pass "unattended-upgrades enabled"
else
  # file-based enable counts too
  if grep -Eq 'Unattended-Upgrade "1"|APT::Periodic::Unattended-Upgrade "1"' /etc/apt/apt.conf.d/* 2>/dev/null; then
    pass "unattended-upgrades enabled"
  else
    fail "unattended-upgrades not enabled"
  fi
fi

reboot_flag="$(awk -F'"' '/Unattended-Upgrade::Automatic-Reboot /{print tolower($2); exit}' <<<"${apt_dump}")"
if [[ -z "${reboot_flag}" ]]; then
  # grep fragments
  if grep -Rqi 'Automatic-Reboot.*"false"' /etc/apt/apt.conf.d/ 2>/dev/null; then
    reboot_flag="false"
  fi
fi
if [[ "${reboot_flag}" == "false" || "${reboot_flag}" == "0" ]]; then
  pass "unattended automatic reboot is off"
else
  fail "unattended automatic reboot is not off (Automatic-Reboot=${reboot_flag:-unset})"
fi

# --- fail2ban ---
if systemctl is-active --quiet fail2ban; then
  pass "fail2ban is active"
else
  fail "fail2ban is not active"
fi

# --- Docker ---
if command -v docker >/dev/null 2>&1; then
  pass "Docker present ($(docker --version | tr -d '\r'))"
else
  fail "Docker binary missing"
fi

if docker compose version >/dev/null 2>&1; then
  pass "Docker Compose plugin present ($(docker compose version | tr -d '\r'))"
else
  fail "Docker Compose plugin missing"
fi

# --- Swap >= 4 GB ---
swap_kb="$(awk '/^SwapTotal:/ {print $2}' /proc/meminfo)"
# 4 GiB = 4194304 kB; allow small rounding (e.g. 4G fallocate)
if [[ -n "${swap_kb}" && "${swap_kb}" -ge 4000000 ]]; then
  pass "swap >= 4 GB (${swap_kb} kB)"
else
  fail "swap < 4 GB (SwapTotal=${swap_kb:-0} kB)"
fi

# --- Docker log limits ---
if [[ -f /etc/docker/daemon.json ]] \
  && grep -q '"log-driver"[[:space:]]*:[[:space:]]*"local"' /etc/docker/daemon.json \
  && grep -q 'max-size' /etc/docker/daemon.json; then
  pass "Docker local log driver with size limits configured"
else
  fail "Docker daemon.json missing local log driver / size limits"
fi

# --- Monitoring agent ---
if systemctl is-active --quiet do-agent 2>/dev/null \
  || systemctl is-active --quiet droplet-agent 2>/dev/null \
  || pgrep -f 'do-agent|droplet-agent' >/dev/null 2>&1; then
  pass "DigitalOcean monitoring agent running"
else
  fail "DigitalOcean monitoring agent not running"
fi

# --- /opt/oxytrip ---
if [[ -d /opt/oxytrip ]]; then
  owner="$(stat -c '%U' /opt/oxytrip)"
  if [[ "${owner}" == "deploy" ]]; then
    pass "/opt/oxytrip present and owned by deploy"
  else
    fail "/opt/oxytrip owned by ${owner}, expected deploy"
  fi
else
  fail "/opt/oxytrip missing"
fi

echo
echo "Summary: ${PASS} passed, ${FAIL} failed"
if [[ "${FAIL}" -gt 0 ]]; then
  exit 1
fi
exit 0
