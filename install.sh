#!/usr/bin/env bash
# =========================================================
# Danmu / LogVar 弹幕 API 一键安装（最终稳定版）
# 适用：Debian 11/12/13、Ubuntu 20.04/22.04/24.04
# 架构：Docker + 系统 Nginx + 可选 HTTPS + 可选 Cloudflare DNS
#
# 设计目标：
# - 不依赖 1Panel / OpenResty
# - 不引入 Docker 官方 apt 仓库（避免 Debian 上误加 Ubuntu 源导致 404）
# - 只管理“本脚本创建”的站点与容器；可选“接管 Nginx”清空现有站点
# =========================================================

set -Eeuo pipefail

APP_NAME="danmu-api"
DOCKER_IMAGE_DEFAULT="logvar/danmu-api:latest"
CONTAINER_PORT="9321"
INFO_FILE="/root/danmu-info.txt"

# ---------- 输出/日志 ----------
c_reset="\033[0m"; c_red="\033[31m"; c_green="\033[32m"; c_yellow="\033[33m"; c_blue="\033[34m"; c_cyan="\033[36m"
log()  { echo -e "${c_cyan}[INFO]${c_reset} $*"; }
ok()   { echo -e "${c_green}[OK]${c_reset} $*"; }
warn() { echo -e "${c_yellow}[WARN]${c_reset} $*"; }
err()  { echo -e "${c_red}[ERR]${c_reset} $*"; }

die() { err "$*"; exit 1; }

on_error() {
  local exit_code=$?
  err "脚本执行失败（exit=$exit_code）。请把屏幕最后 30 行发我排查。"
  exit $exit_code
}
trap on_error ERR

need_root() {
  [[ "${EUID}" -eq 0 ]] || die "请用 root 运行：sudo -i 后再执行脚本"
}

# ---------- 工具 ----------
has_cmd() { command -v "$1" >/dev/null 2>&1; }

read_yn() {
  local prompt="$1" default="${2:-N}" ans
  while true; do
    read -r -p "$prompt [y/N] (默认:$default): " ans || true
    ans="${ans:-$default}"
    case "${ans,,}" in
      y|yes) echo "y"; return;;
      n|no)  echo "n"; return;;
      *) echo "请输入 y 或 n";;
    esac
  done
}

read_text() {
  local prompt="$1" default="${2:-}" var
  read -r -p "$prompt${default:+ (默认: $default)}: " var || true
  echo "${var:-$default}"
}

is_debian_like() {
  [[ -f /etc/os-release ]] || return 1
  # shellcheck disable=SC1091
  . /etc/os-release
  [[ "${ID:-}" == "debian" || "${ID_LIKE:-}" == *"debian"* || "${ID:-}" == "ubuntu" || "${ID_LIKE:-}" == *"ubuntu"* ]]
}

apt_install_base() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y ca-certificates curl jq nginx certbot python3-certbot-nginx docker.io
  systemctl enable --now nginx docker
}

docker_clean_previous() {
  if has_cmd docker; then
    if docker ps -a --format '{{.Names}}' | grep -qx "$APP_NAME"; then
      log "删除旧容器：$APP_NAME"
      docker rm -f "$APP_NAME" >/dev/null 2>&1 || true
      ok "旧容器已删除"
    fi
  fi
}

nginx_takeover_cleanup() {
  local takeover="$1"
  if [[ "$takeover" == "y" ]]; then
    warn "你选择了“接管 Nginx”：将清空 /etc/nginx/sites-enabled 和 sites-available 下的所有站点文件。"
    rm -f /etc/nginx/sites-enabled/* || true
    rm -f /etc/nginx/sites-available/* || true
    ok "Nginx 站点目录已清空"
  fi
}

write_nginx_http_only_conf() {
  local domain="$1" webroot="$2" conf="/etc/nginx/sites-available/${domain}.conf"
  cat > "$conf" <<EOF
server {
  listen 80;
  server_name ${domain};

  location /.well-known/acme-challenge/ {
    root ${webroot};
  }

  location / {
    return 200 "ACME OK\n";
    add_header Content-Type text/plain;
  }
}
EOF
  ln -sf "$conf" "/etc/nginx/sites-enabled/${domain}.conf"
}

write_nginx_https_conf() {
  local domain="$1" webroot="$2" upstream_port="$3"
  local conf="/etc/nginx/sites-available/${domain}.conf"
  cat > "$conf" <<EOF
# ${domain} - managed by danmu install script
server {
  listen 80;
  server_name ${domain};

  location /.well-known/acme-challenge/ {
    root ${webroot};
  }

  location / {
    return 301 https://\$host\$request_uri;
  }
}

server {
  listen 443 ssl http2;
  server_name ${domain};

  ssl_certificate     /etc/letsencrypt/live/${domain}/fullchain.pem;
  ssl_certificate_key /etc/letsencrypt/live/${domain}/privkey.pem;

  ssl_protocols TLSv1.2 TLSv1.3;

  location / {
    proxy_pass http://127.0.0.1:${upstream_port};
    proxy_http_version 1.1;

    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;

    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection "upgrade";
  }
}
EOF
  ln -sf "$conf" "/etc/nginx/sites-enabled/${domain}.conf"
}

nginx_reload_strict() {
  nginx -t
  systemctl reload nginx
}

certbot_issue_webroot() {
  local domain="$1" email="$2" webroot="$3"
  mkdir -p "$webroot/.well-known/acme-challenge"
  certbot certonly --webroot -w "$webroot" -d "$domain" \
    --agree-tos --email "$email" --non-interactive --keep-until-expiring
}

# ---------- Cloudflare DNS（可选） ----------
cf_api() {
  local method="$1" url="$2" token="$3" data="${4:-}"
  if [[ -n "$data" ]]; then
    curl -fsS -X "$method" "https://api.cloudflare.com/client/v4${url}" \
      -H "Authorization: Bearer ${token}" \
      -H "Content-Type: application/json" \
      --data "$data"
  else
    curl -fsS -X "$method" "https://api.cloudflare.com/client/v4${url}" \
      -H "Authorization: Bearer ${token}" \
      -H "Content-Type: application/json"
  fi
}

cf_upsert_A_record() {
  local zone_id="$1" token="$2" name="$3" content_ip="$4" proxied="$5"

  # 查询现有记录
  local q
  q="$(cf_api GET "/zones/${zone_id}/dns_records?type=A&name=${name}" "$token")" || die "Cloudflare API 请求失败（查询 DNS 记录）。"
  local success
  success="$(echo "$q" | jq -r '.success')" || true
  [[ "$success" == "true" ]] || die "Cloudflare 返回失败：$(echo "$q" | jq -c '.errors')"

  local rec_id
  rec_id="$(echo "$q" | jq -r '.result[0].id // empty')"

  local payload
  payload="$(jq -nc --arg type "A" --arg name "$name" --arg content "$content_ip" --argjson proxied "$proxied" \
              '{type:$type,name:$name,content:$content,ttl:1,proxied:$proxied}')" || true

  if [[ -n "$rec_id" ]]; then
    log "Cloudflare：更新 A 记录 $name -> $content_ip (proxied=$proxied)"
    local r
    r="$(cf_api PUT "/zones/${zone_id}/dns_records/${rec_id}" "$token" "$payload")" || die "Cloudflare API 请求失败（更新 DNS 记录）。"
    [[ "$(echo "$r" | jq -r '.success')" == "true" ]] || die "更新失败：$(echo "$r" | jq -c '.errors')"
    ok "DNS 记录已更新"
  else
    log "Cloudflare：创建 A 记录 $name -> $content_ip (proxied=$proxied)"
    local r
    r="$(cf_api POST "/zones/${zone_id}/dns_records" "$token" "$payload")" || die "Cloudflare API 请求失败（创建 DNS 记录）。"
    [[ "$(echo "$r" | jq -r '.success')" == "true" ]] || die "创建失败：$(echo "$r" | jq -c '.errors')"
    ok "DNS 记录已创建"
  fi
}

# ---------- 主流程 ----------
main() {
  need_root
  is_debian_like || die "仅支持 Debian/Ubuntu 系。"

  clear || true
  echo -e "${c_blue}Danmu 一键安装（最终稳定版）${c_reset}"
  echo "（Docker + Nginx + 可选 HTTPS + 可选 Cloudflare DNS）"
  echo

  # 选择是否接管 Nginx（清空现有站点）
  local takeover
  takeover="$(read_yn "是否“接管 Nginx”（清空 /etc/nginx/sites-available 和 sites-enabled 现有站点）？" "N")"

  # 域名（可空）
  local domain
  domain="$(read_text "请输入域名（没有就直接回车，仅用 IP:端口 访问）" "")"
  domain="${domain,,}"

  # 端口与镜像
  local upstream_port
  upstream_port="$(read_text "弹幕服务宿主机端口（Nginx 反代/外部访问将到这个端口）" "8080")"
  [[ "$upstream_port" =~ ^[0-9]+$ ]] || die "端口必须是数字"

  local docker_image
  docker_image="$(read_text "弹幕 Docker 镜像" "$DOCKER_IMAGE_DEFAULT")"

  # Token
  local normal_token admin_token
  normal_token="$(read_text "普通访问 Token（路径用，例如 /123987455）" "123987455")"
  admin_token="$(read_text "管理员 Token（路径用，例如 /admin_888999；无需写 admin_ 前缀也可）" "888999")"
  # 规范化 admin token
  if [[ "$admin_token" != admin_* ]]; then
    admin_token="admin_${admin_token}"
  fi

  # Cloudflare DNS（可选）
  local use_cf cf_token zone_id cf_record_name proxied_flag
  use_cf="$(read_yn "是否使用 Cloudflare API 自动创建/更新 DNS A 记录？（需要 Token+ZoneID）" "N")"
  if [[ "$use_cf" == "y" ]]; then
    cf_token="$(read_text "输入 Cloudflare API Token（需：Zone:Read + DNS:Edit）" "")"
    zone_id="$(read_text "输入 Cloudflare Zone ID（区域 ID，不是账户 ID）" "")"
    [[ -n "$cf_token" && -n "$zone_id" ]] || die "Cloudflare Token/ZoneID 不能为空"

    # 记录名：如果有域名，默认用域名；否则让用户输入
    if [[ -n "$domain" ]]; then
      cf_record_name="$(read_text "DNS 记录全名（例如 dm.example.com）" "$domain")"
    else
      cf_record_name="$(read_text "DNS 记录全名（例如 dm.example.com）" "")"
      [[ -n "$cf_record_name" ]] || die "未输入 DNS 记录名"
    fi

    # content IP：不自动探测，避免暴露；必须用户输入
    local content_ip
    content_ip="$(read_text "请输入服务器公网 IP（用于 A 记录 content；不会自动检测）" "")"
    [[ -n "$content_ip" ]] || die "未输入公网 IP"

    # 是否橙云
    local proxied
    proxied="$(read_yn "A 记录是否开启橙云代理（Proxied）？" "Y")"
    if [[ "$proxied" == "y" ]]; then
      proxied_flag="true"
    else
      proxied_flag="false"
    fi

    # 执行 upsert
    cf_upsert_A_record "$zone_id" "$cf_token" "$cf_record_name" "$content_ip" "$proxied_flag"
  fi

  # HTTPS（仅在有域名时）
  local enable_https email
  enable_https="n"
  email=""
  if [[ -n "$domain" ]]; then
    enable_https="$(read_yn "是否启用 HTTPS（Let's Encrypt）？（要求：域名已解析到本机，且申请证书时建议灰云）" "Y")"
    if [[ "$enable_https" == "y" ]]; then
      email="$(read_text "请输入证书邮箱（Let's Encrypt 用于到期通知）" "admin@${domain}")"
    fi
  fi

  echo
  echo "========== 配置预览 =========="
  echo "域名: ${domain:-<无>}"
  echo "Upstream: http://127.0.0.1:${upstream_port}  (Docker 映射到容器 ${CONTAINER_PORT})"
  echo "镜像: ${docker_image}"
  echo "容器名: ${APP_NAME}"
  echo "普通 Token: /${normal_token}"
  echo "管理员 Token: /${admin_token}"
  echo "Cloudflare: ${use_cf}"
  echo "HTTPS: ${enable_https}"
  echo "接管 Nginx: ${takeover}"
  echo "=============================="
  echo

  # 安装基础组件
  log "安装/更新依赖（nginx / docker / certbot / jq）..."
  apt_install_base
  ok "依赖已安装"

  # 清理旧容器
  docker_clean_previous

  # Nginx 清理（可选）
  nginx_takeover_cleanup "$takeover"

  # 启动 Docker 服务
  log "拉取并启动弹幕容器..."
  docker pull "$docker_image"
  docker run -d \
    --name "$APP_NAME" \
    --restart unless-stopped \
    -p "${upstream_port}:${CONTAINER_PORT}" \
    "$docker_image"
  ok "容器已启动：$APP_NAME"

  # 域名为空：直接输出 IP:端口访问方式
  if [[ -z "$domain" ]]; then
    cat > "$INFO_FILE" <<EOF
[Danmu 安装完成 - 无域名模式]
访问方式（你需要用服务器公网 IP）：

普通：
  http://<你的服务器IP>:${upstream_port}/${normal_token}

管理：
  http://<你的服务器IP>:${upstream_port}/${admin_token}

Docker:
  容器：${APP_NAME}
  镜像：${docker_image}
  端口：${upstream_port} -> ${CONTAINER_PORT}

提示：
- 如果你不想暴露 IP，建议使用域名 + Cloudflare 橙云，然后启用 HTTPS。
EOF
    ok "安装完成。输出文件：$INFO_FILE"
    echo
    echo "===== 访问地址（无域名）====="
    echo "普通： http://<你的服务器IP>:${upstream_port}/${normal_token}"
    echo "管理： http://<你的服务器IP>:${upstream_port}/${admin_token}"
    echo "============================"
    exit 0
  fi

  # 域名模式：写 Nginx
  mkdir -p /var/www/html
  log "配置 Nginx（域名站点）..."
  if [[ "$enable_https" == "y" ]]; then
    # 先写 HTTP-only，确保 ACME 走得通
    write_nginx_http_only_conf "$domain" "/var/www/html"
    nginx_reload_strict
    ok "HTTP 站点已就绪（用于申请证书）"

    warn "申请证书时：建议 Cloudflare 暂时灰云（DNS only）。证书成功后再开橙云。"
    log "申请 Let's Encrypt 证书..."
    certbot_issue_webroot "$domain" "$email" "/var/www/html"
    ok "证书申请成功"

    # 写入最终 HTTPS 配置
    write_nginx_https_conf "$domain" "/var/www/html" "$upstream_port"
    nginx_reload_strict
    ok "HTTPS 反代已启用"
  else
    # HTTP 反代
    local conf="/etc/nginx/sites-available/${domain}.conf"
    cat > "$conf" <<EOF
# ${domain} - managed by danmu install script (HTTP only)
server {
  listen 80;
  server_name ${domain};

  location / {
    proxy_pass http://127.0.0.1:${upstream_port};
    proxy_http_version 1.1;

    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;

    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection "upgrade";
  }
}
EOF
    ln -sf "$conf" "/etc/nginx/sites-enabled/${domain}.conf"
    nginx_reload_strict
    ok "HTTP 反代已启用"
  fi

  # 输出信息
  local scheme="http"
  [[ "$enable_https" == "y" ]] && scheme="https"

  cat > "$INFO_FILE" <<EOF
[Danmu 安装完成]
域名：${domain}
协议：${scheme}
Nginx -> Upstream：http://127.0.0.1:${upstream_port}
Docker：${APP_NAME} (${docker_image})

普通访问：
  ${scheme}://${domain}/${normal_token}

管理访问：
  ${scheme}://${domain}/${admin_token}

常用命令：
  docker logs -f ${APP_NAME}
  docker restart ${APP_NAME}
  nginx -t && systemctl reload nginx

HTTPS 续期：
  certbot renew --dry-run
EOF

  ok "安装完成。输出文件：$INFO_FILE"
  echo
  echo "===== 访问地址（请复制）====="
  echo "普通： ${scheme}://${domain}/${normal_token}"
  echo "管理： ${scheme}://${domain}/${admin_token}"
  echo "输出： ${INFO_FILE}"
  echo "============================"

  # 提醒冲突排查
  if nginx -t 2>&1 | grep -qi "conflict"; then
    warn "检测到 Nginx 有冲突提示（conflicting server name）。"
    warn "执行：nginx -T | grep -n \"server_name ${domain}\"  可以定位重复站点。"
  fi
}

main "$@"
