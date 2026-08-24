#!/bin/bash
# =============================================================================
# Hermes Agent VPS — Bare-metal one-shot installer (Ubuntu 24.04 / 26.04)
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/tinovn/vps-hermes-management/main/install.sh | \
#     bash -s -- [--mgmt-key <KEY>] [--domain <FQDN>]
#
#   bash install.sh [--mgmt-key <KEY>] [--domain <FQDN>] [--ref <git-ref>]
#
# Flags:
#   --mgmt-key   Pre-supplied Management API key (auto-gen if omitted)
#   --domain     FQDN for Caddy Let's Encrypt (auto-detect from hostname if omitted)
#   --ref        Hermes git ref (branch/tag/SHA, default: main)
#   --skip-hermes  Skip Hermes Agent install (useful for mgmt-api-only updates)
#   --with-rag   Install the local RAG MCP service + register it with Hermes
#   --skip-zalo  Skip the Zalo personal plugin (installed by default)
# WhatsApp bridge deps are NOT installed here — the dashboard installs them
# on demand via POST /api/whatsapp/install (see management-api routes/whatsapp.py).
# =============================================================================

set -euo pipefail

# ---- Constants ------------------------------------------------------------
readonly APP_NAME="hermes-vps"
readonly APP_VERSION="0.1.0"
readonly MGMT_REPO_RAW="https://raw.githubusercontent.com/tinovn/vps-hermes-management/main"
readonly HERMES_REPO_URL="https://github.com/NousResearch/hermes-agent.git"
readonly INSTALL_DIR="/opt/hermes"
readonly HERMES_SRC_DIR="${INSTALL_DIR}/hermes-agent"
readonly MGMT_DIR="/opt/hermes-mgmt"
readonly RAG_DIR="/opt/hermes-rag"
readonly TEMPLATES_DIR="/etc/hermes/config"
readonly LOG_FILE="/var/log/hermes-install.log"
readonly MGMT_API_PORT=9997
readonly DASHBOARD_PORT=9119
readonly RAG_PORT=9998
# Light multilingual embedder (good for Vietnamese + English on a 4GB box).
# Override per-install with the RAG_EMBED_MODEL env var in /opt/hermes/.env.
readonly RAG_EMBED_MODEL_DEFAULT="sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2"
readonly HERMES_EXTRAS="web,messaging,cron,voice,mcp,honcho"
readonly PYTHON_PIN="3.11"

# Zalo personal plugin (unofficial Zalo Web API via zca-js Node sidecar).
# Installed by default into the gateway's HERMES_HOME plugins dir; skip with --skip-zalo.
readonly ZALO_PLUGIN_REPO="https://github.com/tinovn/hermes-zalo-plugin"
readonly ZALO_PLUGIN_NAME="zalo-personal"

# ---- Args -----------------------------------------------------------------
MGMT_API_KEY_ARG=""
DOMAIN_ARG=""
HERMES_REF="main"
SKIP_HERMES=false
WITH_RAG=true
WITH_ZALO=true
while [[ $# -gt 0 ]]; do
  case $1 in
    --mgmt-key)   MGMT_API_KEY_ARG="$2"; shift 2 ;;
    --domain)     DOMAIN_ARG="$2"; shift 2 ;;
    --ref)        HERMES_REF="$2"; shift 2 ;;
    --skip-hermes) SKIP_HERMES=true; shift ;;
    --with-rag)   WITH_RAG=true; shift ;;
    --skip-zalo)  WITH_ZALO=false; shift ;;
    -h|--help)
      sed -n '3,14p' "$0" | sed 's/^# //' | sed 's/^#$//'
      exit 0 ;;
    *) shift ;;
  esac
done

# ---- Logging --------------------------------------------------------------
mkdir -p "$(dirname "$LOG_FILE")"
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE" >&2; }
die() { log "FATAL: $*"; exit 1; }
step() { log ""; log "==== $* ===="; }

log "=== hermes-vps installer ${APP_VERSION} starting ==="

# ---- 1. OS check ----------------------------------------------------------
step "1. OS check"
if [[ ! -f /etc/os-release ]]; then
  die "/etc/os-release not found"
fi
. /etc/os-release
case "${ID:-}:${VERSION_ID:-}" in
  ubuntu:24.04|ubuntu:26.04) ;;
  *) die "Unsupported OS: ${PRETTY_NAME:-unknown}. Required: Ubuntu 24.04 or 26.04" ;;
esac
if [[ "$(id -u)" != "0" ]]; then
  die "Must run as root"
fi
log "OS OK: ${PRETTY_NAME}"

# ---- 1b. Pre-flight: disk + RAM ------------------------------------------
DISK_AVAIL_GB=$(df -BG --output=avail / | tail -1 | tr -dc '0-9')
MEM_TOTAL_MB=$(awk '/^MemTotal:/ {print int($2/1024)}' /proc/meminfo)
log "Pre-flight: disk=${DISK_AVAIL_GB}GB free, RAM=${MEM_TOTAL_MB}MB total"
if [[ "${DISK_AVAIL_GB:-0}" -lt 6 ]]; then
  die "Insufficient disk: need >=6GB free on /, have ${DISK_AVAIL_GB}GB"
fi
if [[ "${MEM_TOTAL_MB:-0}" -lt 900 ]]; then
  die "Insufficient RAM: need >=1GB, have ${MEM_TOTAL_MB}MB"
fi

# ---- 2. Apt lock handling -------------------------------------------------
step "2. Apt lock + cloud-init wait"

systemctl stop unattended-upgrades 2>/dev/null || true
systemctl disable unattended-upgrades 2>/dev/null || true
systemctl stop apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true
systemctl disable apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true
systemctl kill --kill-who=all apt-daily.service apt-daily-upgrade.service unattended-upgrades.service 2>/dev/null || true
killall -9 unattended-upgr apt apt-get dpkg 2>/dev/null || true
sleep 3

rm -f /var/lib/dpkg/lock /var/lib/dpkg/lock-frontend /var/lib/apt/lists/lock /var/cache/apt/archives/lock 2>/dev/null || true
rm -f /var/lib/dpkg/updates/* 2>/dev/null || true
dpkg --force-confdef --force-confold --configure -a 2>/dev/null || true

is_apt_locked() {
  if command -v lsof &>/dev/null; then
    lsof /var/lib/dpkg/lock /var/lib/dpkg/lock-frontend /var/lib/apt/lists/lock /var/cache/apt/archives/lock 2>/dev/null | grep -q .
    return $?
  fi
  fuser /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/lib/apt/lists/lock 2>/dev/null
}

wait_for_apt() {
  local max=180 waited=0
  while [[ $waited -lt $max ]]; do
    if ! is_apt_locked; then
      return 0
    fi
    log "apt lock held, waiting 5s (${waited}s/${max}s)..."
    sleep 5
    waited=$((waited + 5))
  done
  log "WARN: apt lock still held after ${max}s, forcing release"
  killall -9 apt apt-get dpkg unattended-upgr 2>/dev/null || true
  rm -f /var/lib/dpkg/lock /var/lib/dpkg/lock-frontend /var/lib/apt/lists/lock /var/cache/apt/archives/lock 2>/dev/null
  dpkg --force-confdef --force-confold --configure -a 2>/dev/null || true
}

apt_retry() {
  local retries=3 i=0
  while [[ $i -lt $retries ]]; do
    wait_for_apt
    if "$@"; then return 0; fi
    i=$((i + 1))
    log "apt retry ${i}/${retries}: cleaning lock + reconfiguring dpkg..."
    killall -9 apt apt-get dpkg 2>/dev/null || true
    rm -f /var/lib/dpkg/lock /var/lib/dpkg/lock-frontend /var/lib/apt/lists/lock /var/cache/apt/archives/lock 2>/dev/null || true
    rm -f /var/lib/dpkg/updates/* 2>/dev/null || true
    dpkg --force-confdef --force-confold --configure -a 2>/dev/null || true
    sleep 5
  done
  log "FATAL: apt command failed after ${retries} attempts: $*"
  return 1
}

wait_for_apt

# ---- 3. Detect domain -----------------------------------------------------
# Helper: read a key from /opt/hermes/.env (empty if missing/file absent).
# Defined early because domain + several tokens read from the same file.
read_env_value() {
  local key="$1" file="${INSTALL_DIR}/.env"
  [[ -f "$file" ]] || { echo ""; return; }
  awk -F= -v k="$key" '$1 == k { sub("^[^=]*=", ""); print; exit }' "$file"
}

step "3. Detect domain"
DROPLET_IP=$(hostname -I | awk '{print $1}')
if [[ -z "$DROPLET_IP" ]]; then
  DROPLET_IP=$(curl -sf --max-time 5 https://api.ipify.org 2>/dev/null || echo "127.0.0.1")
fi

# Domain precedence (highest -> lowest):
#   1. Existing DOMAIN= in /opt/hermes/.env (pre-seeded by bootstrap.sh)
#   2. --domain CLI flag
#   3. hostname -f (when it's a real FQDN)
#   4. <ip>.sslip.io fallback
EXISTING_DOMAIN=$(read_env_value DOMAIN)
if [[ -n "$EXISTING_DOMAIN" ]]; then
  DOMAIN="$EXISTING_DOMAIN"
  log "Domain (from .env): ${DOMAIN}"
elif [[ -n "$DOMAIN_ARG" ]]; then
  DOMAIN="$DOMAIN_ARG"
  log "Domain (from flag): ${DOMAIN}"
else
  HOSTNAME_FQDN=$(hostname -f 2>/dev/null || hostname)
  if [[ "$HOSTNAME_FQDN" == *.* && "$HOSTNAME_FQDN" != "localhost."* ]]; then
    DOMAIN="$HOSTNAME_FQDN"
    log "Domain (from hostname -f): ${DOMAIN}"
  else
    DOMAIN="${DROPLET_IP}.sslip.io"
    log "Domain (sslip.io fallback): ${DOMAIN}"
  fi
fi

# ---- 4. DNS pre-check (non-fatal) -----------------------------------------
step "4. DNS pre-check"
DNS_READY=false

# Resolve via DoH first (1.1.1.1) — bypass /etc/hosts which often maps the VPS
# hostname to 127.0.1.1 on Ubuntu, then fall back to getent for non-public domains.
resolve_domain() {
  local d="$1" r=""
  r=$(curl -sf --max-time 5 "https://1.1.1.1/dns-query?name=${d}&type=A" \
      -H "accept: application/dns-json" 2>/dev/null \
    | grep -oE '"data":[ ]*"[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+"' \
    | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+') || true
  if [[ -z "$r" ]]; then
    r=$(getent ahostsv4 "$d" 2>/dev/null \
      | awk '$1 !~ /^127\./ && $1 !~ /^::/ {print $1; exit}')
  fi
  echo "$r"
}

# Skip DNS check entirely for sslip.io fallback (it always resolves correctly)
if [[ "$DOMAIN" == *.sslip.io ]]; then
  DNS_READY=true
  log "DNS skip: sslip.io fallback (always resolves)"
else
  for i in 1 2 3 4 5 6; do
    RESOLVED=$(resolve_domain "$DOMAIN")
    if [[ "$RESOLVED" == "$DROPLET_IP" ]]; then
      DNS_READY=true
      log "DNS OK: ${DOMAIN} -> ${DROPLET_IP}"
      break
    fi
    log "DNS wait ${i}/6: ${DOMAIN} -> ${RESOLVED:-?} (need ${DROPLET_IP})"
    sleep 5
  done
fi

if [[ "$DNS_READY" == "false" ]]; then
  log "WARN: DNS not ready; Caddy will use self-signed TLS"
fi

# ---- 5. System packages ---------------------------------------------------
step "5. Install system packages"
export DEBIAN_FRONTEND=noninteractive
apt_retry apt-get -qqy update
apt_retry apt-get -qqy -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold install \
  curl ca-certificates gnupg ufw fail2ban jq dnsutils git build-essential \
  libssl-dev libffi-dev python3-venv python3-pip ffmpeg \
  debian-keyring debian-archive-keyring apt-transport-https

# ---- 5b. Prefer IPv4 when IPv6 egress is broken ---------------------------
# Some VPS providers assign a global IPv6 address + default route but don't
# actually route IPv6 to the internet. glibc then prefers IPv6 (RFC 3484), so
# Python/httpx stalls ~30s per request (it has no happy-eyeballs fallback like
# curl) — e.g. the Codex device-code login times out before the dashboard can
# read the URL ("Không đọc được URL device-code từ hermes"). If a global IPv6
# address exists but egress is dead, tell getaddrinfo to prefer IPv4 system-wide
# (harmless no-op on hosts with working IPv6 or none at all).
step "5b. Network: prefer IPv4 if IPv6 egress broken"
GAI_PREF="precedence ::ffff:0:0/96  100"
# Match only an ACTIVE precedence line. Ubuntu ships /etc/gai.conf with the very
# same rule as a COMMENTED example ("#precedence ::ffff:0:0/96  100"), so a plain
# substring grep -qF always matched it and this whole step silently no-op'd.
if grep -qE '^[[:space:]]*precedence[[:space:]]+::ffff:0:0/96' /etc/gai.conf 2>/dev/null; then
  log "gai.conf already prefers IPv4 — skipping"
elif ! ip -6 addr show scope global 2>/dev/null | grep -q 'inet6'; then
  log "No global IPv6 address — nothing to do"
elif curl -6 -sS -m 6 -o /dev/null https://cloudflare.com 2>/dev/null \
   || curl -6 -sS -m 6 -o /dev/null https://www.google.com 2>/dev/null; then
  log "IPv6 egress OK — leaving DNS preference unchanged"
else
  log "IPv6 present but egress broken — forcing IPv4 preference in /etc/gai.conf"
  cp -n /etc/gai.conf "/etc/gai.conf.bak.$(date +%F)" 2>/dev/null || true
  printf '\n# Prefer IPv4 over IPv6 (broken IPv6 egress) — added by hermes install.sh %s\n%s\n' \
    "$(date +%F)" "$GAI_PREF" >> /etc/gai.conf
fi

# ---- 6. Install uv + Python 3.11 ------------------------------------------
step "6. Install uv + Python 3.11"
if ! command -v uv &>/dev/null; then
  curl -LsSf https://astral.sh/uv/install.sh | sh
  ln -sf /root/.local/bin/uv /usr/local/bin/uv
fi
uv --version
uv python install "$PYTHON_PIN"

# ---- 6b. Install Node.js 22 (required for Hermes web dashboard build) -----
step "6b. Install Node.js 22"
if ! command -v node &>/dev/null || [[ "$(node -v 2>/dev/null)" != v22* ]]; then
  # Ubuntu 26.04 already ships nodejs 22 and NodeSource has no `resolute`
  # build (404), so prefer the distro package whenever it is already v22.
  if apt-cache policy nodejs 2>/dev/null | grep -q "Candidate: 22\."; then
    apt_retry apt-get -qqy install nodejs
    # Debian's nodejs package excludes npm, and the `npm` package drags in
    # ~370 node-* packages (+1.2 GB). corepack ships with node 22 and pulls
    # npm on demand instead.
    corepack enable npm || die "corepack enable npm failed"
  else
    curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
    apt_retry apt-get -qqy install nodejs
  fi
fi
log "Node: $(node -v) / npm: $(npm -v)"

# ---- 7. Install Caddy -----------------------------------------------------
step "7. Install Caddy"
if ! command -v caddy &>/dev/null; then
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
    | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
    > /etc/apt/sources.list.d/caddy-stable.list
  apt_retry apt-get -qqy update
  apt_retry apt-get -qqy install caddy
fi
log "Caddy: $(caddy version | head -1)"

# ---- 8. UFW (idempotent — preserves user-added rules) ---------------------
step "8. Configure UFW"
ufw_rule_exists() { ufw status 2>/dev/null | grep -qE "^${1}\b"; }

# Set defaults only if firewall not yet active (preserve operator changes)
if ! ufw status 2>/dev/null | grep -q "Status: active"; then
  ufw default deny incoming
  ufw default allow outgoing
fi

ufw_rule_exists "80/tcp"                  || ufw allow 80/tcp  comment 'http'
ufw_rule_exists "443/tcp"                 || ufw allow 443/tcp comment 'https'
ufw_rule_exists "${MGMT_API_PORT}/tcp"    || ufw allow "${MGMT_API_PORT}/tcp" comment 'hermes-mgmt'
ufw status 2>/dev/null | grep -q "22/tcp.*LIMIT" || ufw limit ssh/tcp
ufw --force enable

# ---- 9. Install layout ----------------------------------------------------
step "9. Create install layout"
mkdir -p "${INSTALL_DIR}" "${INSTALL_DIR}/.hermes" "${INSTALL_DIR}/data"
mkdir -p "${MGMT_DIR}" "${TEMPLATES_DIR}" "${TEMPLATES_DIR}/channels"
mkdir -p /var/log/caddy
if [[ "$WITH_RAG" == "true" ]]; then
  mkdir -p "${RAG_DIR}" "${RAG_DIR}/data" "${RAG_DIR}/docs"
fi

# ---- 10. Install Hermes Agent (editable via uv) ---------------------------
if [[ "$SKIP_HERMES" != "true" ]]; then
  step "10. Install Hermes Agent (ref=${HERMES_REF})"
  if [[ ! -d "${HERMES_SRC_DIR}/.git" ]]; then
    git clone "${HERMES_REPO_URL}" "${HERMES_SRC_DIR}"
  fi
  cd "${HERMES_SRC_DIR}"
  git fetch --tags origin
  git checkout "${HERMES_REF}"
  git pull --ff-only origin "${HERMES_REF}" 2>/dev/null || true

  if [[ ! -d "${HERMES_SRC_DIR}/.venv" ]]; then
    uv venv --python "$PYTHON_PIN" "${HERMES_SRC_DIR}/.venv"
  fi
  # shellcheck source=/dev/null
  VIRTUAL_ENV="${HERMES_SRC_DIR}/.venv" uv pip install --python "${HERMES_SRC_DIR}/.venv/bin/python" \
    -e ".[${HERMES_EXTRAS}]"

  ln -sf "${HERMES_SRC_DIR}/.venv/bin/hermes" /usr/local/bin/hermes
  log "Hermes: $(/usr/local/bin/hermes version 2>/dev/null | head -1 || echo 'installed')"

  # Build web dashboard ahead of time — Hermes auto-build during systemd start
  # fails (no TTY, kills child npm processes after 7s).
  if [[ -d "${HERMES_SRC_DIR}/web" && ! -d "${HERMES_SRC_DIR}/hermes_cli/web_dist" ]]; then
    log "Building Hermes web dashboard (npm install + build)..."
    pushd "${HERMES_SRC_DIR}/web" >/dev/null
    npm install --no-audit --no-fund --loglevel=error
    npm run build
    popd >/dev/null
    log "Web dashboard built"
  fi

  # Default config tweaks: clean cron delivery. Upstream wraps every scheduled
  # job message with "Cronjob Response: ..." / "(job_id: ...)" / "To stop or
  # manage this job..." boilerplate (cron/scheduler.py, wrap_response default
  # true) — end users should only see the actual content. Idempotent merge.
  log "Setting cron.wrap_response=false (clean cron messages)..."
  mkdir -p /root/.hermes
  HERMES_HOME=/root/.hermes "${HERMES_SRC_DIR}/.venv/bin/python" - <<'PYEOF' >>"${LOG_FILE}" 2>&1 || log "WARN: could not set cron.wrap_response=false — set it in config.yaml manually"
import os, yaml
p = os.path.join(os.environ["HERMES_HOME"], "config.yaml")
d = {}
if os.path.exists(p):
    d = yaml.safe_load(open(p)) or {}
c = d.get("cron")
if not isinstance(c, dict):
    c = {}
c["wrap_response"] = False
d["cron"] = c
yaml.safe_dump(d, open(p, "w"), allow_unicode=True, sort_keys=False)
print("cron.wrap_response=false")
PYEOF
else
  log "Skipping Hermes install (--skip-hermes)"
fi

# ---- 11. Install management-api (FastAPI) ---------------------------------
step "11. Install management-api"
cd "${MGMT_DIR}"
if [[ ! -d .git ]]; then
  if [[ -f "${MGMT_DIR}/pyproject.toml" ]]; then
    log "Mgmt API sources already present, skipping download"
  else
    log "Downloading management-api sources from ${MGMT_REPO_RAW}"
    for f in pyproject.toml \
             hermes_mgmt/__init__.py hermes_mgmt/main.py hermes_mgmt/config.py \
             hermes_mgmt/auth.py hermes_mgmt/deps.py hermes_mgmt/models.py \
             hermes_mgmt/env_file.py hermes_mgmt/systemd_ctl.py \
             hermes_mgmt/cli_runner.py hermes_mgmt/hermes_fs.py \
             hermes_mgmt/routes/__init__.py hermes_mgmt/routes/status.py \
             hermes_mgmt/routes/control.py hermes_mgmt/routes/config_routes.py \
             hermes_mgmt/routes/channels.py hermes_mgmt/routes/cron_routes.py \
             hermes_mgmt/routes/logs.py hermes_mgmt/routes/auth_routes.py \
             hermes_mgmt/routes/env_routes.py hermes_mgmt/routes/cli_routes.py \
             hermes_mgmt/routes/zalo.py hermes_mgmt/routes/openviking.py \
             hermes_mgmt/routes/whatsapp.py hermes_mgmt/assets/whatsapp_pair.mjs \
             hermes_mgmt/routes/codex.py hermes_mgmt/routes/roles.py \
             hermes_mgmt/routes/maintenance.py hermes_mgmt/routes/insights.py; do
      mkdir -p "$(dirname "${MGMT_DIR}/${f}")"
      curl -fsSL "${MGMT_REPO_RAW}/management-api/${f}" -o "${MGMT_DIR}/${f}" \
        || die "Failed to fetch ${f}"
    done

    # Role/rule policy config (the roles API reads config/rules/*.md +
    # config/roles/*.yaml from /opt/hermes-mgmt/config). Fetch the file list
    # DYNAMICALLY via the GitHub contents API so new roles/rules added upstream
    # are always included — no hardcoded list to keep in sync.
    fetch_config_dir() {
      local sub="$1"  # rules | roles
      mkdir -p "${MGMT_DIR}/config/${sub}"
      local api="https://api.github.com/repos/tinovn/vps-hermes-management/contents/config/${sub}"
      # Parse "name": "x.md" entries from the JSON (no jq dependency).
      local names
      names=$(curl -fsSL "$api" 2>/dev/null | grep -oE '"name": *"[^"]+"' | sed -E 's/"name": *"([^"]+)"/\1/')
      if [[ -z "$names" ]]; then
        log "WARN: could not list config/${sub} via GitHub API — roles may be limited"
        return
      fi
      local n
      for n in $names; do
        curl -fsSL "${MGMT_REPO_RAW}/config/${sub}/${n}" -o "${MGMT_DIR}/config/${sub}/${n}" \
          || log "WARN: could not fetch config/${sub}/${n}"
      done
      log "Fetched config/${sub}: $(echo "$names" | wc -w | tr -d ' ') files"
    }
    fetch_config_dir rules
    fetch_config_dir roles
  fi
fi

if [[ ! -d "${MGMT_DIR}/.venv" ]]; then
  uv venv --python "$PYTHON_PIN" "${MGMT_DIR}/.venv"
fi
VIRTUAL_ENV="${MGMT_DIR}/.venv" uv pip install --python "${MGMT_DIR}/.venv/bin/python" \
  -e "${MGMT_DIR}"

# ---- 11b. Install Zalo personal plugin -----------------------------------
# Hermes discovers plugins from ${HERMES_HOME}/plugins/<name>/. Our gateway
# service runs as User=root with HOME unset, so HERMES_HOME resolves to
# /root/.hermes — that is where the gateway looks. The plugin ships a Python
# adapter + a Node.js sidecar (zca-js) that the gateway spawns as a child.
if [[ "$WITH_ZALO" == "true" && "$SKIP_HERMES" != "true" ]]; then
  step "11b. Install Zalo personal plugin"
  ZALO_PLUGIN_DIR="/root/.hermes/plugins/${ZALO_PLUGIN_NAME}"
  mkdir -p "$(dirname "${ZALO_PLUGIN_DIR}")"
  if [[ ! -d "${ZALO_PLUGIN_DIR}/.git" ]]; then
    rm -rf "${ZALO_PLUGIN_DIR}"
    git clone --depth 1 "${ZALO_PLUGIN_REPO}" "${ZALO_PLUGIN_DIR}" \
      || log "WARN: Zalo plugin clone failed — skipping (set up later by hand)"
  else
    git -C "${ZALO_PLUGIN_DIR}" pull --ff-only 2>/dev/null || true
  fi

  if [[ -f "${ZALO_PLUGIN_DIR}/sidecar/package.json" ]]; then
    log "Installing Zalo sidecar Node deps (zca-js)..."
    pushd "${ZALO_PLUGIN_DIR}/sidecar" >/dev/null
    npm install --no-audit --no-fund --loglevel=error \
      || log "WARN: Zalo sidecar npm install failed — run it manually before use"
    popd >/dev/null
    # Default session/data dir for the sidecar (overridable via .env).
    mkdir -p /opt/data/zalo

    # Hermes discovers plugins in the dir but ships them DISABLED — must enable
    # explicitly or the gateway never loads the adapter ("No messaging platforms
    # enabled"). For a FLAT plugin (no category prefix) the registry key is the
    # `name:` field from plugin.yaml (zalo-personal-platform), NOT the directory
    # name — see hermes_cli/plugins.py: `key = prefix/dir if prefix else name`.
    ZALO_PLUGIN_ID="$(grep -E '^name:' "${ZALO_PLUGIN_DIR}/plugin.yaml" 2>/dev/null | head -1 | cut -d: -f2 | xargs)"
    ZALO_PLUGIN_ID="${ZALO_PLUGIN_ID:-${ZALO_PLUGIN_NAME}}"
    log "Enabling Hermes plugin '${ZALO_PLUGIN_ID}'..."
    HERMES_HOME=/root/.hermes /usr/local/bin/hermes plugins enable "${ZALO_PLUGIN_ID}" \
      >>"${LOG_FILE}" 2>&1 \
      || log "WARN: 'hermes plugins enable ${ZALO_PLUGIN_ID}' failed — enable it from the dashboard/CLI"

    # Flip platforms.zalo-personal.enabled in config.yaml. Enabling the plugin
    # only LOADS the adapter; the gateway only STARTS a platform (and spawns its
    # sidecar) when its config.yaml platforms.<id>.enabled is true — otherwise it
    # logs "No messaging platforms enabled". Platform id = the id the adapter
    # passes to ctx.register_platform() (zalo-personal), NOT the plugin key.
    HERMES_HOME=/root/.hermes /opt/hermes/hermes-agent/.venv/bin/python - <<'PYEOF' >>"${LOG_FILE}" 2>&1 || log "WARN: could not flip platforms.zalo-personal.enabled — set it from the dashboard"
import os, yaml
p = os.path.join(os.environ["HERMES_HOME"], "config.yaml")
d = yaml.safe_load(open(p)) or {}
pl = d.get("platforms")
if not isinstance(pl, dict):
    pl = {}
e = pl.get("zalo-personal")
if not isinstance(e, dict):
    e = {}
e["enabled"] = True
pl["zalo-personal"] = e
d["platforms"] = pl
yaml.safe_dump(d, open(p, "w"), allow_unicode=True, sort_keys=False)
print("platforms.zalo-personal.enabled=true")
PYEOF
    log "Zalo plugin installed + enabled at ${ZALO_PLUGIN_DIR}"
  else
    log "WARN: Zalo plugin sources incomplete — sidecar not built"
  fi
else
  log "Skipping Zalo plugin (--skip-zalo or --skip-hermes)"
fi

# NOTE: WhatsApp bridge deps (Baileys) are intentionally NOT installed here.
# The dashboard installs them on demand via POST /api/whatsapp/install, which
# handles the prerequisites (git HTTPS rewrite for Baileys' ssh sub-dep, plus a
# swapfile on low-RAM boxes so the TypeScript build doesn't OOM). See
# management-api/hermes_mgmt/routes/whatsapp.py.

# ---- 12. Generate tokens + .env ------------------------------------------
# Token precedence (highest -> lowest):
#   1. Existing value in ${INSTALL_DIR}/.env (pre-seeded by bootstrap.sh /
#      provisioning system / re-run installer). Never rotated.
#   2. --mgmt-key CLI flag (HOSTBILL / orchestrator)
#   3. Freshly generated via `openssl rand`
# read_env_value() is defined earlier (step 3) so DOMAIN lookup can share it.
step "12. Generate tokens + .env"

# Generate a fresh token only if needed; never overwrite an existing value.
EXISTING_GATEWAY_TOKEN=$(read_env_value HERMES_GATEWAY_TOKEN)
EXISTING_MGMT_API_KEY=$(read_env_value HERMES_MGMT_API_KEY)
EXISTING_SESSION_SECRET=$(read_env_value HERMES_MGMT_SESSION_SECRET)
EXISTING_AUTH_TOKEN=$(read_env_value HERMES_AUTH_TOKEN)

GATEWAY_TOKEN="${EXISTING_GATEWAY_TOKEN:-$(openssl rand -hex 32)}"
MGMT_API_KEY="${EXISTING_MGMT_API_KEY:-${MGMT_API_KEY_ARG:-$(openssl rand -hex 32)}}"
SESSION_SECRET="${EXISTING_SESSION_SECRET:-$(openssl rand -hex 32)}"
AUTH_TOKEN="${EXISTING_AUTH_TOKEN:-$(openssl rand -hex 24)}"

if [[ "$DNS_READY" == "true" ]]; then
  CADDY_TLS_VALUE=""
else
  CADDY_TLS_VALUE="tls internal"
fi

if [[ ! -f "${INSTALL_DIR}/.env" ]]; then
  cat > "${INSTALL_DIR}/.env" <<EOF
# hermes-vps environment — written by install.sh $(date -u +%FT%TZ)
# After changes: systemctl restart hermes-gateway hermes-dashboard hermes-mgmt caddy

# --- Core ---
# HERMES_HOME: set EXPLICITLY to the same path the CLI resolves by default
# (\$HOME/.hermes with HOME=/root for our root services). Required by the
# Zalo plugin adapter: its owner-gate reads \${HERMES_HOME}/sessions/sessions.json
# and falls back to /opt/data when unset — on a fresh VPS that path has no
# sessions store, so the fail-closed gate would block every zalo_* tool
# (even the owner's). Keep this in sync with the service units' HOME.
HERMES_HOME=/root/.hermes
HERMES_VPS_VERSION=${APP_VERSION}
HERMES_DROPLET_IP=${DROPLET_IP}
DOMAIN=${DOMAIN}
CADDY_TLS=${CADDY_TLS_VALUE}

# --- Ports ---
HERMES_DASHBOARD_PORT=${DASHBOARD_PORT}
HERMES_MGMT_PORT=${MGMT_API_PORT}

# --- RAG MCP service (only used when installed with --with-rag) ---
# Local document retrieval exposed to Hermes over MCP at 127.0.0.1:${RAG_PORT}/mcp.
RAG_PORT=${RAG_PORT}
RAG_EMBED_MODEL=${RAG_EMBED_MODEL_DEFAULT}
RAG_DATA_DIR=${RAG_DIR}/data
RAG_DOCS_DIR=${RAG_DIR}/docs
# Higher-quality multilingual alternative (needs ~2GB RAM — also raise
# MemoryMax in /etc/systemd/system/hermes-rag.service and re-ingest after reset):
# RAG_EMBED_MODEL=intfloat/multilingual-e5-large

# --- Auth ---
HERMES_GATEWAY_TOKEN=${GATEWAY_TOKEN}
HERMES_MGMT_API_KEY=${MGMT_API_KEY}
HERMES_MGMT_SESSION_SECRET=${SESSION_SECRET}
HERMES_AUTH_TOKEN=${AUTH_TOKEN}

# --- Provider API keys (fill what you use) ---
# OPENAI_API_KEY=
# ANTHROPIC_API_KEY=
# NOUS_API_KEY=
# OPENROUTER_API_KEY=
# HUGGINGFACE_TOKEN=

# --- Messaging platform tokens (fill what you use) ---
# TELEGRAM_BOT_TOKEN=
# DISCORD_BOT_TOKEN=
# SLACK_BOT_TOKEN=
# SLACK_APP_TOKEN=
# SIGNAL_ACCOUNT=

# --- Zalo personal plugin (zalo-personal) ---
# Unofficial Zalo Web API via zca-js Node sidecar. USE A SECONDARY NUMBER —
# bulk friend/message actions risk account bans. First run needs QR login:
#   curl -X POST http://127.0.0.1:3838/login/qr  &&  open http://127.0.0.1:3838/qr.png
# Required: owner Zalo UID (message the bot once, then grep gateway log for from_uid=).
ZALO_PERSONAL_OWNER_UID=
ZALO_PERSONAL_SIDECAR_PORT=3838
ZALO_PERSONAL_SESSION_DIR=/opt/data/zalo
# Let anyone who messages the bot chat without a per-user approval step.
# Set to false to require approving each new user (owner is always allowed).
ZALO_PERSONAL_ALLOW_ALL_USERS=true
# Optional:
# ZALO_PERSONAL_ALLOWED_USERS=
# ZALO_PERSONAL_PROXY=
# ZALO_OWNER_NICKNAME=sếp
# ZALO_OWNER_NAME=
# GOOGLE_TOKEN_PATH=
# ZALO_PERSONAL_HOME_THREAD=
EOF
  chmod 600 "${INSTALL_DIR}/.env"
  log "Wrote ${INSTALL_DIR}/.env (fresh)"
else
  log "Preserving existing ${INSTALL_DIR}/.env"
  # Append any auth keys still missing (preserve every pre-seeded value).
  [[ -n "$EXISTING_GATEWAY_TOKEN" ]]   || echo "HERMES_GATEWAY_TOKEN=${GATEWAY_TOKEN}"           >> "${INSTALL_DIR}/.env"
  [[ -n "$EXISTING_MGMT_API_KEY" ]]    || echo "HERMES_MGMT_API_KEY=${MGMT_API_KEY}"             >> "${INSTALL_DIR}/.env"
  [[ -n "$EXISTING_SESSION_SECRET" ]]  || echo "HERMES_MGMT_SESSION_SECRET=${SESSION_SECRET}"    >> "${INSTALL_DIR}/.env"
  [[ -n "$EXISTING_AUTH_TOKEN" ]]      || echo "HERMES_AUTH_TOKEN=${AUTH_TOKEN}"                 >> "${INSTALL_DIR}/.env"
  log "  GATEWAY_TOKEN: $([[ -n "$EXISTING_GATEWAY_TOKEN"  ]] && echo "preserved" || echo "appended")"
  log "  MGMT_API_KEY : $([[ -n "$EXISTING_MGMT_API_KEY"   ]] && echo "preserved" || echo "appended")"
  log "  SESSION_SECRET: $([[ -n "$EXISTING_SESSION_SECRET" ]] && echo "preserved" || echo "appended")"
  log "  AUTH_TOKEN   : $([[ -n "$EXISTING_AUTH_TOKEN"     ]] && echo "preserved" || echo "appended")"
  # HERMES_HOME: required by the Zalo plugin owner-gate (see fresh-.env comment).
  # Old VPS installs lack it — append so the adapter resolves sessions.json.
  if ! grep -q '^HERMES_HOME=' "${INSTALL_DIR}/.env"; then
    echo "HERMES_HOME=/root/.hermes" >> "${INSTALL_DIR}/.env"
    log "  HERMES_HOME  : appended (/root/.hermes — Zalo owner-gate fix)"
  fi
  # Seed Zalo plugin env block on re-run if absent (preserve any existing value).
  if [[ "$WITH_ZALO" == "true" ]] && ! grep -q '^ZALO_PERSONAL_OWNER_UID=' "${INSTALL_DIR}/.env"; then
    cat >> "${INSTALL_DIR}/.env" <<'ZEOF'

# --- Zalo personal plugin (zalo-personal) — appended by installer ---
# Unofficial Zalo Web API via zca-js. USE A SECONDARY NUMBER (ban risk).
# First run QR login: curl -X POST http://127.0.0.1:3838/login/qr ; open /qr.png
ZALO_PERSONAL_OWNER_UID=
ZALO_PERSONAL_SIDECAR_PORT=3838
ZALO_PERSONAL_SESSION_DIR=/opt/data/zalo
ZALO_PERSONAL_ALLOW_ALL_USERS=true
# ZALO_PERSONAL_ALLOWED_USERS=
# ZALO_PERSONAL_PROXY=
# ZALO_OWNER_NICKNAME=sếp
# ZALO_OWNER_NAME=
# GOOGLE_TOKEN_PATH=
# ZALO_PERSONAL_HOME_THREAD=
ZEOF
    log "  ZALO env block: appended"
  fi
fi

# ---- 12b. Install RAG MCP service (optional, --with-rag) ------------------
if [[ "$WITH_RAG" == "true" ]]; then
  step "12b. Install RAG MCP service"
  cd "${RAG_DIR}"
  if [[ ! -f "${RAG_DIR}/pyproject.toml" ]]; then
    log "Downloading rag-mcp sources from ${MGMT_REPO_RAW}"
    for f in pyproject.toml README.md \
             hermes_rag/__init__.py hermes_rag/config.py hermes_rag/chunker.py \
             hermes_rag/embedder.py hermes_rag/store.py hermes_rag/ingest.py \
             hermes_rag/search.py hermes_rag/mcp_server.py hermes_rag/cli.py; do
      mkdir -p "$(dirname "${RAG_DIR}/${f}")"
      curl -fsSL "${MGMT_REPO_RAW}/rag-mcp/${f}" -o "${RAG_DIR}/${f}" \
        || die "Failed to fetch rag-mcp/${f}"
    done
  else
    log "rag-mcp sources already present, skipping download"
  fi

  if [[ ! -d "${RAG_DIR}/.venv" ]]; then
    uv venv --python "$PYTHON_PIN" "${RAG_DIR}/.venv"
  fi
  VIRTUAL_ENV="${RAG_DIR}/.venv" uv pip install --python "${RAG_DIR}/.venv/bin/python" \
    -e "${RAG_DIR}"
  ln -sf "${RAG_DIR}/.venv/bin/hermes-rag" /usr/local/bin/hermes-rag

  # Pre-warm the embedding model so first boot doesn't block on a download.
  RAG_MODEL=$(read_env_value RAG_EMBED_MODEL); RAG_MODEL="${RAG_MODEL:-$RAG_EMBED_MODEL_DEFAULT}"
  RAG_CACHE=$(read_env_value RAG_MODEL_CACHE);  RAG_CACHE="${RAG_CACHE:-${RAG_DIR}/models}"
  mkdir -p "${RAG_CACHE}"
  log "Pre-warming embedding model '${RAG_MODEL}' (first download may take a minute)"
  RAG_EMBED_MODEL="${RAG_MODEL}" RAG_MODEL_CACHE="${RAG_CACHE}" \
    "${RAG_DIR}/.venv/bin/python" -c \
    "from hermes_rag.embedder import build_embedder; build_embedder('${RAG_MODEL}', False, cache_dir='${RAG_CACHE}'); print('model cached')" \
    || log "WARN: model pre-warm failed (will retry on service start)"

  # Register the RAG MCP server in Hermes config.yaml (idempotent). Hermes
  # auto-reloads its mcp_servers section when config.yaml changes.
  # Note: pass the port under a fresh name — RAG_PORT is a readonly constant and
  # using it as a command-prefix assignment would abort the script.
  RAG_CONFIG_FILE="/root/.hermes/config.yaml"
  RAG_MCP_PORT="${RAG_PORT}" RAG_CONFIG_FILE="${RAG_CONFIG_FILE}" \
    "${MGMT_DIR}/.venv/bin/python" - <<'PYEOF' || log "WARN: could not register RAG MCP in config.yaml"
import os, pathlib, yaml
cfg_path = pathlib.Path(os.environ["RAG_CONFIG_FILE"])
cfg = {}
if cfg_path.exists():
    cfg = yaml.safe_load(cfg_path.read_text(encoding="utf-8")) or {}
servers = cfg.setdefault("mcp_servers", {})
servers["rag"] = {
    "url": f"http://127.0.0.1:{os.environ['RAG_MCP_PORT']}/mcp",
    "timeout": 180,
    "connect_timeout": 30,
}
cfg_path.parent.mkdir(parents=True, exist_ok=True)
cfg_path.write_text(yaml.safe_dump(cfg, sort_keys=False, allow_unicode=True), encoding="utf-8")
print(f"Registered mcp_servers.rag -> {servers['rag']['url']}")
PYEOF
  log "RAG MCP registered in ${RAG_CONFIG_FILE}"
fi

# ---- 13. Seed config templates -------------------------------------------
step "13. Seed provider/channel templates"
# Provider templates — keep in sync with config/*.json in this repo + with the
# _PROVIDER_BASE_URLS map in management-api/hermes_mgmt/routes/config_routes.py
for tpl in anthropic openai google xai \
           deepseek groq mistral together \
           nous-portal openrouter huggingface \
           kimi mimo minimax zai \
           openai-codex; do
  curl -fsSL "${MGMT_REPO_RAW}/config/${tpl}.json" \
    -o "${TEMPLATES_DIR}/${tpl}.json" 2>/dev/null \
    || log "WARN: template ${tpl}.json not fetched (may not exist yet)"
done
for ch in telegram discord slack signal whatsapp email; do
  curl -fsSL "${MGMT_REPO_RAW}/config/channels/${ch}.json" \
    -o "${TEMPLATES_DIR}/channels/${ch}.json" 2>/dev/null \
    || log "WARN: channel template ${ch}.json not fetched"
done

# ---- 14. Write Caddyfile -------------------------------------------------
step "14. Write Caddyfile"
cat > "${INSTALL_DIR}/Caddyfile" <<'CADDYFILE'
{
    email admin@{$DOMAIN}
    admin off
}

{$DOMAIN} {
    {$CADDY_TLS}

    header {
        Strict-Transport-Security "max-age=31536000; includeSubDomains"
        X-Content-Type-Options "nosniff"
        X-Frame-Options "SAMEORIGIN"
        Referrer-Policy "strict-origin-when-cross-origin"
        -Server
    }

    # ---- Dashboard auth gate ----
    # First-visit URL:  https://<domain>/?token=$HERMES_AUTH_TOKEN
    #   -> sets persistent cookie, strips token from history (302 to /)
    # Subsequent visits: cookie hermes_auth=<token> grants access (30 days)
    # Without either:    403 with hint
    @auth_via_query {
        query token={$HERMES_AUTH_TOKEN}
    }
    handle @auth_via_query {
        header Set-Cookie "hermes_auth={$HERMES_AUTH_TOKEN}; Path=/; Max-Age=2592000; HttpOnly; Secure; SameSite=Lax"
        redir https://{host}/ 302
    }

    @auth_via_cookie {
        header Cookie *hermes_auth={$HERMES_AUTH_TOKEN}*
    }
    handle @auth_via_cookie {
        # Hermes owns /api/* (status, sessions, env, model, providers, logs).
        # Rewrite Host so its strict Host header check passes. Management API
        # stays on its own port (9997) — its /api/* would conflict.
        reverse_proxy 127.0.0.1:9119 {
            header_up Host "localhost:9119"
            header_up Origin "http://127.0.0.1:9119"
            flush_interval -1
            transport http {
                read_timeout 24h
            }
        }
    }

    handle {
        respond "Forbidden. Append ?token=<HERMES_AUTH_TOKEN> to authenticate." 403
    }

    log {
        output file /var/log/caddy/access.log {
            roll_size 50mb
            roll_keep 5
        }
    }
}
CADDYFILE

# ---- 15. Write systemd units ---------------------------------------------
step "15. Write systemd units"

# Target so we can start/stop all 3 Hermes services atomically
cat > /etc/systemd/system/hermes.target <<'EOF'
[Unit]
Description=Hermes Agent target (gateway + dashboard + management API)
Wants=hermes-gateway.service hermes-dashboard.service hermes-mgmt.service
After=network-online.target

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/hermes-gateway.service <<EOF
[Unit]
Description=Hermes Agent — Messaging Gateway
After=network-online.target
Wants=network-online.target
PartOf=hermes.target

[Service]
Type=simple
User=root
# Leave HOME unset — systemd defaults it to /root for User=root, matching
# what 'hermes gateway setup' writes if an admin ever runs it interactively.
# Without this match, the CLI would silently rewrite the unit and split the
# config store across /root/.hermes and /opt/hermes/.hermes.
WorkingDirectory=${INSTALL_DIR}
EnvironmentFile=${INSTALL_DIR}/.env
Environment=PYTHONUNBUFFERED=1
ExecStart=/usr/local/bin/hermes gateway run
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal
# 1.5G headroom: the Zalo plugin spawns a Node.js sidecar (zca-js) as a child
# of this process, so it shares the gateway cgroup memory budget.
MemoryMax=1536M

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/hermes-dashboard.service <<EOF
[Unit]
Description=Hermes Agent — Web Dashboard (FastAPI)
After=network-online.target
Wants=network-online.target
PartOf=hermes.target

[Service]
Type=simple
User=root
WorkingDirectory=${INSTALL_DIR}
EnvironmentFile=${INSTALL_DIR}/.env
Environment=PYTHONUNBUFFERED=1
ExecStart=/usr/local/bin/hermes dashboard --no-open --host 127.0.0.1 --port ${DASHBOARD_PORT}
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal
MemoryMax=1024M

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/hermes-mgmt.service <<EOF
[Unit]
Description=Hermes VPS Management API (FastAPI)
After=network-online.target
Wants=network-online.target
PartOf=hermes.target

[Service]
Type=simple
User=root
WorkingDirectory=${MGMT_DIR}
EnvironmentFile=${INSTALL_DIR}/.env
Environment=PYTHONUNBUFFERED=1
Environment=HERMES_INSTALL_DIR=${INSTALL_DIR}
Environment=HERMES_TEMPLATES_DIR=${TEMPLATES_DIR}
ExecStart=${MGMT_DIR}/.venv/bin/uvicorn hermes_mgmt.main:app --host 0.0.0.0 --port ${MGMT_API_PORT} --workers 1
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal
MemoryMax=512M

[Install]
WantedBy=multi-user.target
EOF

if [[ "$WITH_RAG" == "true" ]]; then
cat > /etc/systemd/system/hermes-rag.service <<EOF
[Unit]
Description=Hermes Agent — RAG MCP service (local retrieval)
After=network-online.target
Wants=network-online.target
PartOf=hermes.target

[Service]
Type=simple
User=root
WorkingDirectory=${RAG_DIR}
EnvironmentFile=${INSTALL_DIR}/.env
Environment=PYTHONUNBUFFERED=1
ExecStart=${RAG_DIR}/.venv/bin/hermes-rag serve
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal
MemoryMax=1536M

[Install]
WantedBy=hermes.target
EOF
fi

# Caddy override — use our Caddyfile + .env
mkdir -p /etc/systemd/system/caddy.service.d
cat > /etc/systemd/system/caddy.service.d/override.conf <<EOF
[Service]
EnvironmentFile=${INSTALL_DIR}/.env
ExecStart=
ExecStart=/usr/bin/caddy run --environ --config ${INSTALL_DIR}/Caddyfile --adapter caddyfile
EOF

systemctl daemon-reload

# ---- 16. Enable + start ---------------------------------------------------
step "16. Enable + start services"
systemctl enable hermes.target hermes-gateway.service hermes-dashboard.service hermes-mgmt.service caddy.service fail2ban.service
systemctl restart caddy.service
systemctl start hermes-mgmt.service
if [[ "$WITH_RAG" == "true" ]]; then
  systemctl enable hermes-rag.service
  systemctl start hermes-rag.service || log "WARN: hermes-rag start failed (check 'journalctl -u hermes-rag')"
fi
# Gateway + dashboard only start if Hermes was installed (may lack config)
if [[ "$SKIP_HERMES" != "true" ]]; then
  systemctl start hermes-dashboard.service || log "WARN: dashboard start failed (config pending)"
  systemctl start hermes-gateway.service   || log "WARN: gateway start failed (config pending — run 'hermes gateway setup')"
fi
systemctl restart fail2ban.service

# ---- 17. Health wait ------------------------------------------------------
step "17. Health wait"
for i in $(seq 1 18); do
  if curl -sf "http://127.0.0.1:${MGMT_API_PORT}/health" >/dev/null 2>&1; then
    log "mgmt-api healthy after ${i}x5s"
    break
  fi
  sleep 5
done

# ---- 18. Cleanup ----------------------------------------------------------
step "18. Cleanup"
apt-get -qqy autoremove
apt-get -qqy autoclean

# ---- 19. Print success banner --------------------------------------------
SCHEME="https"  # Caddy serves https either via Let's Encrypt or self-signed

svc_status() {
  local svc="$1"
  if systemctl is-active --quiet "$svc"; then
    echo "OK"
  else
    echo "FAIL ($(systemctl is-active "$svc" 2>&1))"
  fi
}

log ""
log "============================================================"
log "  hermes-vps install complete"
log "============================================================"
log ""
log "  Service status:"
log "    caddy             : $(svc_status caddy.service)"
log "    hermes-mgmt       : $(svc_status hermes-mgmt.service)"
log "    hermes-gateway    : $(svc_status hermes-gateway.service)"
log "    hermes-dashboard  : $(svc_status hermes-dashboard.service)"
log "    fail2ban          : $(svc_status fail2ban.service)"
[[ "$WITH_RAG" == "true" ]] && log "    hermes-rag        : $(svc_status hermes-rag.service)"
log ""
log "  Dashboard URL (first visit, sets a 30d cookie then strips token):"
log "    ${SCHEME}://${DOMAIN}/?token=${AUTH_TOKEN}"
log ""
log "  Management API: http://${DROPLET_IP}:${MGMT_API_PORT}  (port-only, not proxied via Caddy)"
log "  TLS mode:       $([[ "$DNS_READY" == "true" ]] && echo "Let's Encrypt" || echo "self-signed (DNS not ready)")"
log ""
log "  AUTH_TOKEN:     ${AUTH_TOKEN}        (dashboard gate)"
log "  MGMT_API_KEY:   ${MGMT_API_KEY}        (mgmt API bearer)"
log "  GATEWAY_TOKEN:  ${GATEWAY_TOKEN}        (hermes gateway)"
log ""
log "  Next steps:"
log "    hermes gateway setup             # configure messaging channels"
log "    hermes model                     # pick provider + model"
log "    hermes config show               # verify config"
log "    systemctl status hermes-gateway  # inspect services"
log "    journalctl -u hermes-gateway -f  # follow logs"
if [[ "$WITH_RAG" == "true" ]]; then
log ""
log "  RAG knowledge base (MCP tool 'rag_search' available in Hermes chat):"
log "    cp your-docs/* ${RAG_DIR}/docs/   # add md/txt/pdf"
log "    hermes-rag ingest                 # index them"
log "    hermes-rag stats                  # verify"
fi
if [[ "$WITH_ZALO" == "true" && "$SKIP_HERMES" != "true" ]]; then
log ""
log "  Zalo plugin (zalo-personal) — USE A SECONDARY NUMBER (ban risk):"
log "    1) Set ZALO_PERSONAL_OWNER_UID in ${INSTALL_DIR}/.env, then:"
log "       systemctl restart hermes-gateway"
log "    2) QR login (first time only):"
log "       curl -X POST http://127.0.0.1:3838/login/qr"
log "       # then open http://127.0.0.1:3838/qr.png and scan with Zalo app"
log "    Plugin dir: /root/.hermes/plugins/${ZALO_PLUGIN_NAME}"
fi
log ""
log "  Quick health check:"
log "    curl -H 'Authorization: Bearer ${MGMT_API_KEY}' \\"
log "         http://127.0.0.1:${MGMT_API_PORT}/api/status"
log ""
log "============================================================"
