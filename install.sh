#!/usr/bin/env bash
set -euo pipefail

# Danmu 一键安装（Docker + Nginx 反代 + 可选 Cloudflare DNS + 可选 HTTPS/自动续期）
# 适配：Debian/Ubuntu（优先 Debian Bookworm；Ubuntu 也可用）
# 输出：/root/danmu_info.txt

# -----------------------------
# 工具函数
# -----------------------------
c_red(){ printf "\033[31m%s\033[0m\n" "$*"; }
c_grn(){ printf "\033[32m%s\033[0m\n" "$*"; }
c_yel(){ printf "\033[33m%s\033[0m\n" "$*"; }
c_cyn(){ printf "\033[36m%s\033[0m\n" "$*"; }

die(){ c_red "[ERROR] $*"; exit 1; }

need_root(){
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    die "请用 root 运行：sudo -i 之后再执行。"
  fi
}

have_cmd(){ command -v "$1" >/dev/null 2>&1; }

read_default(){
  # $1 prompt, $2 default
  local prompt="$1" def="$2" v
  read -r -p "$prompt (默认: $def): " v || true
  if [[ -z "${v// }" ]]; then echo "$def"; else echo "$v"; fi
}

read_yesno(){
  # $1 prompt, $2 default(y/n)
  local prompt="$1" def="${2,,}" v
  local showdef
  if [[ "$def" == "y" ]]; then showdef="Y/n"; else showdef="y/N"; fi
  read -r -p "$prompt [$showdef]: " v || true
  v="${v,,}"
  if [[ -z "${v// }" ]]; then v="$def"; fi
  [[ "$v" == "y" || "$v" == "yes" ]]
}

os_detect(){
  . /etc/os-release 2>/dev/null || true
  echo "${ID:-unknown}:${VERSION_CODENAME:-}:${VERSION_ID:-}"
}

public_ip_guess(){
  # 不主动暴露真实 IP（用户要求默认随便写一个）
  # 这里默认值给 1.1.1.1；用户可手动填写真实 IP
  echo "1.1.1.1"
}

random_token(){
  tr -dc 'a-zA-Z0-9' </dev/urandom | head -c 10
}

# -----------------------------
# Cloudflare API（DNS upsert）
# -----------------------------
cf_api(){
  # $1 method $2 url $3 json(optional)
  local method="$1" url="$2" data="${3:-}"
  if [[ -n "$data" ]]; then
    curl -fsS -X "$method" "$url" \
      -H "Authorization: Bearer ${CF_TOKEN}" \
      -H "Content-Type: application/json" \
      --data "$data"
  else
    curl -fsS -X "$method" "$url" \
      -H "Authorization: Bearer ${CF_TOKEN}" \
      -H "Content-Type: application/json"
  fi
}

cf_zone_check(){
  local z
  z="$(cf_api GET "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}")" || return 1
  echo "$z" | grep -q '"success":true'
}

cf_dns_get_a(){
  # $1 fqdn
  local name="$1"
  cf_api GET "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records?type=A&name=${name}"
}

cf_dns_upsert_a(){
  # $1 fqdn $2 ip $3 proxied(true/false)
  local name="$1" ip="$2" proxied="$3"
  local resp rid
  resp="$(cf_dns_get_a "$name")" || die "Cloudflare 查询 DNS 失败。"
  rid="$(echo "$resp" | sed -n 's/.*"id":"\([^"]\+\)".*/\1/p' | head -n1 || true)"

  local payload
  payload="$(printf '{"type":"A","name":"%s","content":"%s","ttl":1,"proxied":%s}' "$name" "$ip" "$proxied")"

  if [[ -n "$rid" ]]; then
    cf_api PATCH "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records/${rid}" "$payload" \
      || die "Cloudflare 更新 A 记录失败（PATCH）。"
    echo "$rid"
  else
    cf_api POST "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records" "$payload" \
      || die "Cloudflare 创建 A 记录失败（POST）。"
    # 再查一次拿 id
    resp="$(cf_dns_get_a "$name")" || true
    rid="$(echo "$resp" | sed -n 's/.*"id":"\([^"]\+\)".*/\1/p' | head -n1 || true)"
    echo "${rid:-created}"
  fi
}

# -----------------------------
# Docker 安装（Debian/Ubuntu）
# -----------------------------
install_docker(){
  if have_cmd docker; then
    c_grn "[OK] 检测到 Docker 已安装：$(docker --version 2>/dev/null || true)"
    return 0
  fi

  c_yel "[INFO] 安装 Docker..."
  apt-get update -y
  apt-get install -y ca-certificates curl gnupg lsb-release

  local os id codename
  id="$(. /etc/os-release; echo "${ID}")"
  codename="$(. /etc/os-release; echo "${VERSION_CODENAME:-}")"

  install -m 0755 -d /etc/apt/keyrings

  if [[ "$id" == "debian" ]]; then
    curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
    echo \
"deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian ${codename:-bookworm} stable" \
      > /etc/apt/sources.list.d/docker.list
  elif [[ "$id" == "ubuntu" ]]; then
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
    echo \
"deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${codename:-jammy} stable" \
      > /etc/apt/sources.list.d/docker.list
  else
    die "不支持的系统：$id。"
  fi

  apt-get update -y
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  systemctl enable --now docker
  c_grn "[OK] Docker 安装完成：$(docker --version)"
}

# -----------------------------
# Nginx / Certbot
# -----------------------------
install_nginx_certbot(){
  c_yel "[INFO] 安装 Nginx（以及可选 certbot）..."
  apt-get update -y
  apt-get install -y nginx
  systemctl enable --now nginx

  # certbot 是可选；仅当用户启用 HTTPS 才会装
}

write_nginx_site(){
  # 生成站点配置：/etc/nginx/sites-available/<domain>.conf
  local domain="$1" upstream="127.0.0.1:${NGINX_UPSTREAM_PORT}" enable_https="$2"
  local conf="/etc/nginx/sites-available/${domain}.conf"
  local link="/etc/nginx/sites-enabled/${domain}.conf"

  mkdir -p /var/www/_acme_challenge

  cat >"$conf" <<EOF
# Auto-generated by danmu installer
# Domain: ${domain}
# Upstream: ${upstream}

map \$http_upgrade \$connection_upgrade {
  default upgrade;
  ''      close;
}

server {
  listen 80;
  server_name ${domain};

  # Let's Encrypt HTTP-01 challenge
  location ^~ /.well-known/acme-challenge/ {
    root /var/www/_acme_challenge;
    default_type "text/plain";
    allow all;
  }

  location / {
    proxy_http_version 1.1;
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;

    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection \$connection_upgrade;

    proxy_pass http://${upstream};
  }
}
EOF

  if [[ "$enable_https" == "true" ]]; then
    cat >>"$conf" <<EOF

server {
  listen 443 ssl http2;
  server_name ${domain};

  ssl_certificate     /etc/letsencrypt/live/${domain}/fullchain.pem;
  ssl_certificate_key /etc/letsencrypt/live/${domain}/privkey.pem;

  # 基本安全参数（兼容性优先）
  ssl_protocols TLSv1.2 TLSv1.3;
  ssl_prefer_server_ciphers off;

  location / {
    proxy_http_version 1.1;
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto https;

    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection \$connection_upgrade;

    proxy_pass http://${upstream};
  }
}
EOF
  fi

  rm -f "$link"
  ln -s "$conf" "$link"

  # 关闭默认站点，避免冲突
  rm -f /etc/nginx/sites-enabled/default || true

  nginx -t
  systemctl reload nginx
}

certbot_http01(){
  local domain="$1" email="$2"
  apt-get update -y
  apt-get install -y certbot python3-certbot-nginx

  # 依赖 http-01：要求 DNS 解析到本机，且 Cloudflare 建议临时灰云
  certbot certonly --nginx -d "$domain" --agree-tos -m "$email" --non-interactive --redirect || \
    certbot certonly --nginx -d "$domain" --agree-tos -m "$email" --non-interactive

  systemctl enable --now certbot.timer || true
}

# DNS-01：用 Cloudflare Token 直接签发（无需灰云）
certbot_dns01_cf(){
  local domain="$1" email="$2"
  apt-get update -y
  apt-get install -y certbot python3-certbot-dns-cloudflare

  local cred="/root/.secrets/cf.ini"
  mkdir -p /root/.secrets
  chmod 700 /root/.secrets
  cat >"$cred" <<EOF
dns_cloudflare_api_token = ${CF_TOKEN}
EOF
  chmod 600 "$cred"

  certbot certonly --dns-cloudflare --dns-cloudflare-credentials "$cred" \
    -d "$domain" --agree-tos -m "$email" --non-interactive

  systemctl enable --now certbot.timer || true
}

# -----------------------------
# 清理旧环境（可重复安装）
# -----------------------------
cleanup_old(){
  c_yel "[INFO] 清理旧环境（如存在）..."

  # 停止并删除旧容器（按名称）
  if docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    docker rm -f "${CONTAINER_NAME}" >/dev/null 2>&1 || true
    c_grn "[OK] 已删除旧容器：${CONTAINER_NAME}"
  fi

  # 清理旧 nginx 站点
  if [[ -n "${DOMAIN:-}" ]]; then
    rm -f "/etc/nginx/sites-enabled/${DOMAIN}.conf" "/etc/nginx/sites-available/${DOMAIN}.conf" || true
    # 不主动删除证书（避免误删），如需全删可手动 certbot delete
  fi
}

# -----------------------------
# 主流程
# -----------------------------
need_root

c_cyn "Danmu 一键安装（反代默认开启 / 可选 Cloudflare / 可选 HTTPS）"
echo

# 1) 基本参数
DOMAIN="$(read_default "请输入域名（没有就直接回车；无域名则仅 IP:端口 访问）" "")"
NGINX_ENABLE=true
if [[ -z "${DOMAIN}" ]]; then
  c_yel "[INFO] 未填写域名：将使用 IP:端口 访问。Nginx 仍可用，但不配置 HTTPS。"
fi

HOST_PORT="$(read_default "弹幕服务宿主机端口（外部访问端口）" "8080")"
IMAGE="$(read_default "弹幕 Docker 镜像" "logvar/danmu-api:latest")"
CONTAINER_NAME="$(read_default "弹幕容器名称" "danmu-api")"
CONTAINER_PORT="$(read_default "弹幕容器内部端口（镜像暴露端口）" "9321")"

PUBLIC_TOKEN="$(read_default "普通用户 Token（路径用 /<token>）" "123987455")"
ADMIN_SUFFIX="$(read_default "管理员 Token（路径用 /admin_<token>；无需输入 admin_）" "888999")"
ADMIN_TOKEN="admin_${ADMIN_SUFFIX}"

# 2) Cloudflare DNS（可选）
CF_ENABLE=false
CF_PROXIED=false
if [[ -n "${DOMAIN}" ]]; then
  if read_yesno "是否使用 Cloudflare API 自动创建/更新 DNS A 记录？（需要 Token）" "y"; then
    CF_ENABLE=true
    CF_TOKEN="$(read_default "输入 Cloudflare API Token（必须有 Zone:Read + DNS:Edit）" "")"
    CF_ZONE_ID="$(read_default "输入 Cloudflare Zone ID（区域 ID，不是账户 ID）" "")"
    if [[ -z "${CF_TOKEN}" || -z "${CF_ZONE_ID}" ]]; then
      die "Cloudflare Token / Zone ID 不能为空。"
    fi
    if ! cf_zone_check >/dev/null 2>&1; then
      die "Cloudflare Token/ZoneID 校验失败（无法访问 zone）。请检查 Token 权限/ZoneID。"
    fi

    if read_yesno "A 记录是否开启橙云代理（Proxied）？" "y"; then
      CF_PROXIED=true
    fi
  fi
else
  c_yel "[INFO] 无域名：跳过 Cloudflare DNS。"
fi

# 3) HTTPS（可选）
HTTPS_ENABLE=false
HTTPS_MODE="none"
LE_EMAIL=""
if [[ -n "${DOMAIN}" ]]; then
  if read_yesno "是否启用 HTTPS（Let's Encrypt）？" "y"; then
    HTTPS_ENABLE=true
    LE_EMAIL="$(read_default "请输入证书邮箱（Let's Encrypt）" "admin@${DOMAIN}")"

    if $CF_ENABLE && read_yesno "是否使用 Cloudflare DNS-01（推荐：无需灰云）签发证书？" "y"; then
      HTTPS_MODE="dns01_cf"
    else
      HTTPS_MODE="http01"
      c_yel "[提示] HTTP-01 方式：建议 Cloudflare 暂时灰云（DNS only），签发成功后再切回橙云。"
    fi
  fi
fi

# 4) IP 提示（默认不暴露真实 IP）
SERVER_IP_DEFAULT="$(public_ip_guess)"
SERVER_IP="$(read_default "安装信息展示用 IP（不影响实际服务；可随便填，避免暴露）" "$SERVER_IP_DEFAULT")"

echo
c_cyn "========== 配置预览 =========="
echo "域名: ${DOMAIN:-<无>}"
echo "Upstream: http://127.0.0.1:${HOST_PORT}"
echo "Docker 镜像: ${IMAGE}"
echo "容器名: ${CONTAINER_NAME}"
echo "端口映射: ${HOST_PORT} -> ${CONTAINER_PORT}"
echo "普通 Token: /${PUBLIC_TOKEN}"
echo "管理员 Token: /${ADMIN_TOKEN}"
if $CF_ENABLE; then
  echo "Cloudflare: DNS 自动=是, ZoneID=${CF_ZONE_ID}, proxied=${CF_PROXIED}, 记录=${DOMAIN}"
else
  echo "Cloudflare: DNS 自动=否"
fi
if $HTTPS_ENABLE; then
  echo "HTTPS: 是, 模式=${HTTPS_MODE}, 邮箱=${LE_EMAIL}"
else
  echo "HTTPS: 否"
fi
echo "展示用 IP: ${SERVER_IP}"
c_cyn "=============================="
echo

if ! read_yesno "确认开始安装？" "y"; then
  die "用户取消。"
fi

# 5) 安装依赖
install_docker

if $NGINX_ENABLE; then
  install_nginx_certbot
fi

# 6) 清理旧环境
cleanup_old

# 7) 启动容器
c_yel "[INFO] 拉取镜像并启动容器..."
docker pull "${IMAGE}"
docker run -d --name "${CONTAINER_NAME}" --restart unless-stopped \
  -p "${HOST_PORT}:${CONTAINER_PORT}" \
  "${IMAGE}"

c_grn "[OK] 容器已启动：${CONTAINER_NAME}"
sleep 1

# 8) Nginx 反代（有域名则配置域名站点；无域名则仅提示 IP:端口）
BASE_HTTP_URL=""
BASE_HTTPS_URL=""

if [[ -n "${DOMAIN}" ]]; then
  # 8.1 Cloudflare DNS（可选）
  if $CF_ENABLE; then
    c_yel "[INFO] Cloudflare：写/更新 A 记录 ${DOMAIN} -> (你的服务器 IP)"
    # DNS 内容必须是服务器真实公网 IP（这里不猜，要求用户输入）
    REAL_IP="$(read_default "请输入服务器真实公网 IP（用于 DNS A 记录 content）" "")"
    if [[ -z "$REAL_IP" ]]; then
      die "真实公网 IP 不能为空（否则无法写 A 记录）。"
    fi
    rid="$(cf_dns_upsert_a "${DOMAIN}" "${REAL_IP}" "$( $CF_PROXIED && echo true || echo false )")"
    c_grn "[OK] Cloudflare DNS 已写入/更新（record id: $rid）"
  fi

  # 8.2 先写 HTTP 站点（不带 443），必要时用于签发
  write_nginx_site "${DOMAIN}" "false"
  BASE_HTTP_URL="http://${DOMAIN}"

  # 8.3 HTTPS
  if $HTTPS_ENABLE; then
    if [[ "$HTTPS_MODE" == "dns01_cf" ]]; then
      certbot_dns01_cf "${DOMAIN}" "${LE_EMAIL}"
    else
      certbot_http01 "${DOMAIN}" "${LE_EMAIL}"
    fi
    # 写入带 443 的完整站点
    write_nginx_site "${DOMAIN}" "true"
    BASE_HTTPS_URL="https://${DOMAIN}"
  fi
else
  # 无域名：不写站点；用户直接 IP:端口访问
  BASE_HTTP_URL="http://${SERVER_IP}:${HOST_PORT}"
fi

# 9) 输出信息
INFO_FILE="/root/danmu_info.txt"
cat >"$INFO_FILE" <<EOF
Danmu 安装完成（$(date -Is))

[访问地址]
普通接口:
  ${BASE_HTTPS_URL:-$BASE_HTTP_URL}/${PUBLIC_TOKEN}

管理员后台:
  ${BASE_HTTPS_URL:-$BASE_HTTP_URL}/${ADMIN_TOKEN}

[Docker]
  容器: ${CONTAINER_NAME}
  镜像: ${IMAGE}
  端口: ${HOST_PORT} -> ${CONTAINER_PORT}

[Nginx]
  启用: ${NGINX_ENABLE}
  域名: ${DOMAIN:-<无>}
  Upstream: 127.0.0.1:${HOST_PORT}

[Cloudflare DNS]
  启用: ${CF_ENABLE}
  proxied: ${CF_PROXIED}
  zone_id: ${CF_ZONE_ID:-<无>}

[HTTPS]
  启用: ${HTTPS_ENABLE}
  模式: ${HTTPS_MODE}
  邮箱: ${LE_EMAIL:-<无>}

[常用命令]
  查看容器: docker ps
  看日志:   docker logs -f ${CONTAINER_NAME}
  重启容器: docker restart ${CONTAINER_NAME}
  测试 Nginx: nginx -t
EOF

c_grn "[OK] 安装完成。已输出到：${INFO_FILE}"
echo
c_cyn "==== 访问地址（请复制）===="
echo "普通：${BASE_HTTPS_URL:-$BASE_HTTP_URL}/${PUBLIC_TOKEN}"
echo "管理：${BASE_HTTPS_URL:-$BASE_HTTP_URL}/${ADMIN_TOKEN}"
c_cyn "==========================="
echo
