#!/usr/bin/env bash
set -Eeuo pipefail

APP_NAME="${APP_NAME:-danmu-api}"
APP_DIR="${APP_DIR:-/opt/danmu-api}"
IMAGE="${IMAGE:-logvar/danmu-api:latest}"
HOST_PORT_DEFAULT="${HOST_PORT_DEFAULT:-9321}"
UPDATE_TIME="${UPDATE_TIME:-03:20}"

CONFIG_DIR="${APP_DIR}/config"
CACHE_DIR="${APP_DIR}/.cache"
ENV_FILE="${CONFIG_DIR}/.env"
COMPOSE_FILE="${APP_DIR}/docker-compose.yml"
MANAGER_BIN="/usr/local/bin/danmu-api"
CRON_FILE="/etc/cron.d/danmu-api-update"
UPDATE_LOG="/var/log/danmu-api-update.log"
NGINX_SITE="/etc/nginx/sites-available/danmu-api.conf"
NGINX_SITE_LINK="/etc/nginx/sites-enabled/danmu-api.conf"

DEFAULT_TOKEN="${DEFAULT_TOKEN:-87654321}"
DEFAULT_SOURCE_ORDER="${DEFAULT_SOURCE_ORDER:-bilibili,360,renren,hanjutv,douban,vod,dandan,youku,iqiyi,custom,animeko,leshi,tencent,maiduidui,xigua}"
DEFAULT_OTHER_SERVER="${DEFAULT_OTHER_SERVER:-https://api.danmu.icu}"
DEFAULT_VOD_SERVERS="${DEFAULT_VOD_SERVERS:-zy@https://zy.jinchancaiji.com,789@https://www.caiji.cyou,tingfeng@https://gctf.tfdh.top}"

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
CYAN="\033[36m"
NC="\033[0m"

log() { printf "${GREEN}[INFO]${NC} %s\n" "$*"; }
warn() { printf "${YELLOW}[WARN]${NC} %s\n" "$*"; }
die() { printf "${RED}[ERROR]${NC} %s\n" "$*" >&2; exit 1; }

usage() {
  cat <<EOF
Usage:
  bash install.sh              Clean reinstall ${APP_NAME}
  bash install.sh install      Clean reinstall ${APP_NAME}
  bash install.sh update       Pull latest image and restart
  bash install.sh status       Show status and health check
  bash install.sh logs         Follow logs
  bash install.sh uninstall    Remove container, app files, and updater

Environment overrides:
  APP_DIR=/opt/danmu-api
  IMAGE=logvar/danmu-api:latest
  HOST_PORT_DEFAULT=9321
  UPDATE_TIME=03:20
EOF
}

require_root() {
  [ "$(id -u)" -eq 0 ] || die "Please run as root. Try: sudo -i"
}

ask() {
  local prompt="$1"
  local default="${2:-}"
  local answer
  if [ -n "$default" ]; then
    read -r -p "${prompt} [${default}]: " answer || true
    printf "%s" "${answer:-$default}"
  else
    read -r -p "${prompt}: " answer || true
    printf "%s" "$answer"
  fi
}

yn() {
  local prompt="$1"
  local default="${2:-Y}"
  local suffix answer
  if [ "$default" = "Y" ]; then suffix="Y/n"; else suffix="y/N"; fi
  while true; do
    read -r -p "${prompt} [${suffix}]: " answer || true
    answer="${answer:-$default}"
    case "${answer,,}" in
      y|yes) return 0 ;;
      n|no) return 1 ;;
      *) warn "Please answer y or n." ;;
    esac
  done
}

gen_token() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -base64 32 | tr -d '\n' | tr '/+' '_-' | cut -c1-24
  else
    date +%s%N | sha256sum | cut -c1-24
  fi
}

valid_port() {
  [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

valid_time() {
  [[ "$1" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]
}
