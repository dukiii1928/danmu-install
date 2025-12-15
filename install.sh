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

setup_nginx_https(){
  local domain="$1"
  local upstream_port="$2"

  log "安装 Nginx + Certbot..."
  export DEBIAN_FRONTEND=noninteractive
  apt update -y
  apt install -y nginx certbot python3-certbot-nginx

  systemctl enable nginx
  systemctl start nginx

  # 写站点配置（token 路由模式）
  local conf_name="${domain}.conf"
  local conf_avail="/etc/nginx/sites-available/${conf_name}"
  local conf_enabled="/etc/nginx/sites-enabled/${conf_name}"

  # 避免重复启用导致 server_name 冲突
  rm -f "${conf_enabled}"

  cat >"${conf_avail}" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${domain};

    # /TOKEN 和 /TOKEN/ 兼容，并把 token + 后续路径原样转发给后端
    location ~ ^/([^/]+)(/.*)?$ {
        set \$token \$1;
        set \$rest  \$2;
        if (\$rest = "") { set \$rest "/"; }

        proxy_pass http://127.0.0.1:${upstream_port}/\$token\$rest;
        proxy_http_version 1.1;

        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF

  ln -sf "${conf_avail}" "${conf_enabled}"

  nginx -t
  systemctl reload nginx

  log "申请/部署 HTTPS 证书（需要域名已解析到本机，且放行 80/443）..."
  # 邮箱用占位，用户可自行改；失败也不终止（避免脚本整体失败）
  certbot --nginx -d "${domain}" --non-interactive --agree-tos -m "admin@${domain}" --redirect || true

  nginx -t
  systemctl reload nginx
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

PORT="$(ask '请输入后端端口（本机端口，供 Nginx 反代）' "${DEFAULT_PORT}")"
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

# 绑定域名（可选）
SETUP_DOMAIN=false
DOMAIN=""
if yn "是否自动绑定域名并配置 HTTPS（Nginx+Certbot）？" Y; then
  SETUP_DOMAIN=true
  DOMAIN="$(ask '请输入域名（例如 dm.dukiii1928.xyz）' "")"
  [[ -z "${DOMAIN}" ]] && die "域名不能为空"
fi

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
      - "127.0.0.1:${PORT}:9321"
    volumes:
      - ./config:/app/config
      - ./.cache:/app/.cache
    restart: unless-stopped
EOF

${COMPOSE} -f "${COMPOSE_FILE}" pull
${COMPOSE} -f "${COMPOSE_FILE}" up -d

# 可选：自动更新
if ${AUTO_UPDATE} && [ "$(id -u)" = "0" ]; then
  cat > "${CRON_FILE}" <<EOF
5 3 * * * root cd ${APP_DIR} && ${COMPOSE} pull && ${COMPOSE} up -d > /var/log/danmu-api-autoupdate.log 2>&1
EOF
fi

# 可选：配置域名 + HTTPS
if ${SETUP_DOMAIN} && [ "$(id -u)" = "0" ]; then
  setup_nginx_https "${DOMAIN}" "${PORT}"
fi

IP="$(get_ip)"

echo ""
echo "=== 安装完成 ==="
echo "后端本机端口（供 Nginx 反代）:"
echo "  http://127.0.0.1:${PORT}/${TOKEN}"
echo ""

if ${SETUP_DOMAIN}; then
  echo "普通访问:"
  echo "  https://${DOMAIN}/${TOKEN}"
  echo "管理员访问:"
  echo "  https://${DOMAIN}/${ADMIN_TOKEN}"
  echo ""
  echo "提示：请确保 Cloudflare/阿里云安全组已放行 80/443，DNS 已解析到本机公网 IP。"
else
  echo "普通访问（直连端口，未绑定域名）:"
  echo "  http://${IP}:${PORT}/${TOKEN}"
  echo "管理员访问（直连端口，未绑定域名）:"
  echo "  http://${IP}:${PORT}/${ADMIN_TOKEN}"
fi
