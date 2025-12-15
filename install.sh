#!/usr/bin/env bash
set -euo pipefail

APP_DIR="/opt/danmu-api"
CONTAINER_NAME="danmu-api"
IMAGE="logvar/danmu-api:latest"

DEFAULT_PORT="9321"
DEFAULT_TOKEN="87654321"

DEFAULT_SOURCE_ORDER="360,vod,douban,tencent,youku,iqiyi,imgo,bilibili,renren,hanjutv,bahamut,dandan"
DEFAULT_OTHER_SERVER="https://api.danmu.icu"
DEFAULT_VOD_SERVERS="zy@https://zy.jinchancaiji.com,789@https://www.caiji.cyou,听风@https://gctf.tfdh.top"
DEFAULT_VOD_RETURN_MODE="fastest"
DEFAULT_VOD_REQUEST_TIMEOUT="10000"
DEFAULT_YOUKU_CONCURRENCY="8"

CONFIG_DIR="${APP_DIR}/config"
CACHE_DIR="${APP_DIR}/.cache"
COMPOSE_FILE="${APP_DIR}/docker-compose.yml"
ENV_FILE="${CONFIG_DIR}/.env"
CRON_FILE="/etc/cron.d/danmu-api-autoupdate"

log(){ echo "[INFO] $*"; }
die(){ echo "[ERROR] $*" >&2; exit 1; }

need(){ command -v "$1" >/dev/null 2>&1 || die "缺少命令: $1"; }

compose_cmd(){
  if docker compose version >/dev/null 2>&1; then
    echo "docker compose"
  elif command -v docker-compose >/dev/null 2>&1; then
    echo "docker-compose"
  else
    die "未检测到 docker compose"
  fi
}

yn(){
  local p="$1" d="${2:-Y}" a
  while true; do
    read -rp "$p [${d/Y/Y\/n}${d/N/y\/N}]: " a || true
    a="${a:-$d}"
    case "${a,,}" in y|yes) return 0;; n|no) return 1;; esac
  done
}

ask(){
  local p="$1" d="${2:-}" a
  read -rp "$p [默认 $d]: " a || true
  echo "${a:-$d}"
}

gen_token(){
  openssl rand -base64 24 | tr -d '\n' | tr '/+' '_-' | cut -c1-22
}

container_exists(){
  docker ps -a --format '{{.Names}}' | grep -qx "${CONTAINER_NAME}"
}

port_in_use(){
  ss -lnt 2>/dev/null | awk '{print $4}' | grep -q ":$1$"
}

get_ip(){
  ip route get 8.8.8.8 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}'
}

need docker
COMPOSE="$(compose_cmd)"

echo "=== LogVar 弹幕 一键安装 ==="

if container_exists || [ -d "${APP_DIR}" ]; then
  echo "检测到旧安装"
  if yn "是否彻底删除旧安装？" Y; then
    container_exists && docker rm -f "${CONTAINER_NAME}" || true
    yn "是否删除镜像？" N && docker rmi -f "${IMAGE}" || true
    yn "是否删除安装目录 ${APP_DIR}？" N && rm -rf "${APP_DIR}" || true
  fi
fi

PORT="$(ask '请输入端口' "${DEFAULT_PORT}")"
port_in_use "${PORT}" && yn "端口被占用，继续？" N || true

TOKEN="$(ask '普通 TOKEN' "${DEFAULT_TOKEN}")"
ADMIN_TOKEN="$(ask '管理员 ADMIN_TOKEN' "$(gen_token)")"

SOURCE_ORDER="$(ask 'SOURCE_ORDER' "${DEFAULT_SOURCE_ORDER}")"
OTHER_SERVER="$(ask 'OTHER_SERVER' "${DEFAULT_OTHER_SERVER}")"
VOD_SERVERS="$(ask 'VOD_SERVERS' "${DEFAULT_VOD_SERVERS}")"
VOD_RETURN_MODE="$(ask 'VOD_RETURN_MODE' "${DEFAULT_VOD_RETURN_MODE}")"
VOD_REQUEST_TIMEOUT="$(ask 'VOD_REQUEST_TIMEOUT' "${DEFAULT_VOD_REQUEST_TIMEOUT}")"
YOUKU_CONCURRENCY="$(ask 'YOUKU_CONCURRENCY' "${DEFAULT_YOUKU_CONCURRENCY}")"

echo ""
echo "弹幕颜色模式（单选）："
echo "  1) default"
echo "  2) white   （默认）"
echo "  3) color"
read -rp "请选择 [1-3]: " COLOR_CHOICE
case "${COLOR_CHOICE:-2}" in
  1) CONVERT_COLOR="default" ;;
  3) CONVERT_COLOR="color" ;;
  *) CONVERT_COLOR="white" ;;
esac

CONVERT_TOP_BOTTOM_TO_SCROLL="true"

BILI_COOKIE=""
if yn "是否填写 B 站 Cookie？" N; then
  read -rp "请输入 BILIBILI_COOKIE: " BILI_COOKIE
fi

AUTO_UPDATE=false
yn "是否启用每天凌晨自动更新？" N && AUTO_UPDATE=true

mkdir -p "${CONFIG_DIR}" "${CACHE_DIR}"

cat > "${ENV_FILE}" <<EOF
TOKEN=${TOKEN}
ADMIN_TOKEN=${ADMIN_TOKEN}

SOURCE_ORDER=${SOURCE_ORDER}
OTHER_SERVER=${OTHER_SERVER}
VOD_SERVERS=${VOD_SERVERS}
VOD_RETURN_MODE=${VOD_RETURN_MODE}
VOD_REQUEST_TIMEOUT=${VOD_REQUEST_TIMEOUT}
YOUKU_CONCURRENCY=${YOUKU_CONCURRENCY}

CONVERT_TOP_BOTTOM_TO_SCROLL=${CONVERT_TOP_BOTTOM_TO_SCROLL}
CONVERT_COLOR=${CONVERT_COLOR}
EOF

[ -n "${BILI_COOKIE}" ] && echo "BILIBILI_COOKIE=${BILI_COOKIE}" >> "${ENV_FILE}"

cat > "${COMPOSE_FILE}" <<EOF
services:
  danmu-api:
    image: ${IMAGE}
    container_name: ${CONTAINER_NAME}
    ports:
      - "${PORT}:9321"
    volumes:
      - ./config:/app/config
      - ./.cache:/app/.cache
    restart: unless-stopped
EOF

${COMPOSE} -f "${COMPOSE_FILE}" pull
${COMPOSE} -f "${COMPOSE_FILE}" up -d

if ${AUTO_UPDATE} && [ "$(id -u)" = "0" ]; then
  cat > "${CRON_FILE}" <<EOF
5 3 * * * root cd ${APP_DIR} && ${COMPOSE} pull && ${COMPOSE} up -d > /var/log/danmu-api-autoupdate.log 2>&1
EOF
fi

IP="$(get_ip)"

echo ""
echo "=== 安装完成 ==="
echo "普通访问:"
echo "  http://${IP}:${PORT}/${TOKEN}"
echo "管理员访问:"
echo "  http://${IP}:${PORT}/${ADMIN_TOKEN}"
