#!/usr/bin/env bash
set -euo pipefail

# === 配置区域 ===
APP_DIR="/opt/danmu-api"
CONTAINER_NAME="danmu-api"
IMAGE="logvar/danmu-api:latest"

DEFAULT_PORT="9321"
DEFAULT_TOKEN="87654321"

# 默认环境变量
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

# === 工具函数 ===
log(){ echo -e "\033[32m[INFO] $*\033[0m"; }
warn(){ echo -e "\033[33m[WARN] $*\033[0m"; }
die(){ echo -e "\033[31m[ERROR] $*\033[0m" >&2; exit 1; }

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

# === Nginx HTTPS 安装函数 ===
setup_nginx_https(){
  local domain="$1"
  local upstream_port="$2"

  # 检查系统兼容性
  if [ ! -f /etc/debian_version ]; then
    warn "检测到非 Debian/Ubuntu 系统，脚本不支持自动安装 Nginx。"
    warn "请自行安装 Nginx 并配置反向代理。"
    return
  fi

  log "正在安装 Nginx + Certbot..."
  export DEBIAN_FRONTEND=noninteractive
  apt update -y
  apt install -y nginx certbot python3-certbot-nginx

  systemctl enable nginx
  systemctl start nginx

  # 检查 80 端口是否被占用 (排除 nginx 自身)
  if ss -lnt | grep -q ":80 " && ! pgrep nginx >/dev/null; then
    warn "80 端口被占用，Nginx 可能无法启动，SSL 申请将失败。"
  fi

  # Nginx 配置
  local conf_name="${domain}.conf"
  local conf_avail="/etc/nginx/sites-available/${conf_name}"
  local conf_enabled="/etc/nginx/sites-enabled/${conf_name}"

  # 清理可能存在的冲突
  rm -f "${conf_enabled}"
  rm -f "/etc/nginx/sites-enabled/default" # 移除默认配置防止冲突

  # 写入配置 (优化版：标准反向代理)
  cat >"${conf_avail}" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${domain};

    location / {
        proxy_pass http://127.0.0.1:${upstream_port};
        proxy_http_version 1.1;
        
        # 传递真实 IP 和 Header
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        # WebSocket 支持 (可选，但推荐)
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
EOF

  ln -sf "${conf_avail}" "${conf_enabled}"

  nginx -t || die "Nginx 配置测试失败"
  systemctl reload nginx

  log "开始申请 HTTPS 证书..."
  log "请确保域名 ${domain} 已经解析到本机 IP: $(get_ip)"
  
  # 申请证书
  if certbot --nginx -d "${domain}" --non-interactive --agree-tos -m "admin@${domain}" --redirect; then
    log "证书申请成功！已自动配置 HTTPS 重定向。"
    systemctl reload nginx
  else
    die "证书申请失败。请检查：\n1. 域名是否解析正确\n2. 防火墙是否放行 80/443 端口\n3. 是否有其他服务占用 80 端口"
  fi
}

# === 主逻辑 ===

need docker
COMPOSE="$(compose_cmd)"

echo "=========================================="
echo "    LogVar 弹幕 API 一键部署 (HTTPS版)    "
echo "=========================================="

# 清理旧环境
if container_exists || [ -d "${APP_DIR}" ]; then
  warn "检测到旧安装"
  if yn "是否彻底删除旧安装？" Y; then
    container_exists && docker rm -f "${CONTAINER_NAME}" || true
    yn "是否删除镜像？" N && docker rmi -f "${IMAGE}" || true
    yn "是否删除安装目录 ${APP_DIR}？" N && rm -rf "${APP_DIR}" || true
  fi
fi

# 端口配置
PORT="$(ask '请输入后端端口（本机端口，供 Nginx 反代）' "${DEFAULT_PORT}")"
port_in_use "${PORT}" && yn "端口 $PORT 似乎被占用，是否继续？" N || true

# Token 配置
TOKEN="$(ask '普通 TOKEN' "${DEFAULT_TOKEN}")"
ADMIN_TOKEN="$(ask '管理员 ADMIN_TOKEN' "$(gen_token)")"
if [ "$TOKEN" == "$ADMIN_TOKEN" ]; then
    warn "警告：普通 Token 和 管理员 Token 相同，建议修改！"
fi

# 高级参数配置
SOURCE_ORDER="$(ask 'SOURCE_ORDER' "${DEFAULT_SOURCE_ORDER}")"
OTHER_SERVER="$(ask 'OTHER_SERVER' "${DEFAULT_OTHER_SERVER}")"
VOD_SERVERS="$(ask 'VOD_SERVERS' "${DEFAULT_VOD_SERVERS}")"
VOD_RETURN_MODE="$(ask 'VOD_RETURN_MODE' "${DEFAULT_VOD_RETURN_MODE}")"
VOD_REQUEST_TIMEOUT="$(ask 'VOD_REQUEST_TIMEOUT' "${DEFAULT_VOD_REQUEST_TIMEOUT}")"
YOUKU_CONCURRENCY="$(ask 'YOUKU_CONCURRENCY' "${DEFAULT_YOUKU_CONCURRENCY}")"

echo ""
echo "弹幕颜色模式："
echo "  1) default (不转换)"
echo "  2) white   (全白 - 默认)"
echo "  3) color   (彩色)"
read -rp "请选择 [1-3]: " COLOR_CHOICE
case "${COLOR_CHOICE:-2}" in
  1) CONVERT_COLOR="default" ;;
  3) CONVERT_COLOR="color" ;;
  *) CONVERT_COLOR="white" ;;
esac

# Cookie 配置
BILI_COOKIE=""
if yn "是否填写 B 站 Cookie (SESSDATA)? " N; then
  read -rp "请输入 BILIBILI_COOKIE: " BILI_COOKIE
fi

# 自动更新配置
AUTO_UPDATE=false
yn "是否启用每天凌晨自动更新？" N && AUTO_UPDATE=true

# === 域名与 HTTPS 询问 ===
SETUP_DOMAIN=false
DOMAIN=""
if yn "是否自动绑定域名并配置 HTTPS (需要 Debian/Ubuntu)？" Y; then
  SETUP_DOMAIN=true
  DOMAIN="$(ask '请输入域名（例如 dm.example.com）' "")"
  [[ -z "${DOMAIN}" ]] && die "域名不能为空"
fi

# === 生成配置文件 ===
mkdir -p "${CONFIG_DIR}" "${CACHE_DIR}"

log "生成环境变量文件..."
cat > "${ENV_FILE}" <<EOF
TOKEN=${TOKEN}
ADMIN_TOKEN=${ADMIN_TOKEN}

SOURCE_ORDER=${SOURCE_ORDER}
OTHER_SERVER=${OTHER_SERVER}
VOD_SERVERS=${VOD_SERVERS}
VOD_RETURN_MODE=${VOD_RETURN_MODE}
VOD_REQUEST_TIMEOUT=${VOD_REQUEST_TIMEOUT}
YOUKU_CONCURRENCY=${YOUKU_CONCURRENCY}

CONVERT_TOP_BOTTOM_TO_SCROLL=true
CONVERT_COLOR=${CONVERT_COLOR}
EOF

[ -n "${BILI_COOKIE}" ] && echo "BILIBILI_COOKIE='${BILI_COOKIE}'" >> "${ENV_FILE}"

log "生成 Docker Compose 文件..."
# 注意：这里绑定 127.0.0.1 确保只能通过 Nginx 访问，提高安全性
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

# === 启动服务 ===
log "拉取镜像并启动容器..."
${COMPOSE} -f "${COMPOSE_FILE}" pull
${COMPOSE} -f "${COMPOSE_FILE}" up -d

# === 设置自动更新 ===
if ${AUTO_UPDATE} && [ "$(id -u)" = "0" ]; then
  log "配置自动更新任务..."
  cat > "${CRON_FILE}" <<EOF
5 3 * * * root cd ${APP_DIR} && ${COMPOSE} pull && ${COMPOSE} up -d > /var/log/danmu-api-autoupdate.log 2>&1
EOF
  chmod 644 "${CRON_FILE}"
fi

# === 配置 Nginx HTTPS ===
if ${SETUP_DOMAIN} && [ "$(id -u)" = "0" ]; then
  setup_nginx_https "${DOMAIN}" "${PORT}"
fi

IP="$(get_ip)"

echo ""
echo "################################################"
echo "#                  安装完成                    #"
echo "################################################"

if ${SETUP_DOMAIN}; then
  echo -e "普通访问地址 (填写到播放器):"
  echo -e "  \033[36mhttps://${DOMAIN}/${TOKEN}\033[0m"
  echo ""
  echo -e "管理后台地址:"
  echo -e "  \033[36mhttps://${DOMAIN}/${ADMIN_TOKEN}\033[0m"
  echo ""
  echo "提示：如果是 Cloudflare，请将 SSL 设置为 'Full'。"
else
  echo "未配置域名，仅开启本地端口映射。"
  echo "本机访问地址: http://127.0.0.1:${PORT}/${TOKEN}"
  echo "如果是公网服务器，建议手动配置反向代理。"
fi
echo "################################################"
