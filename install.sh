#!/usr/bin/env bash
set -euo pipefail

# =========================================
# Danmu 一键安装（通用版 + Cloudflare 可选自动化）
# 适用：Ubuntu/Debian（root 执行）
#
# 功能：
# - 安装 Docker 并启动弹幕容器
# - 安装 Nginx 并反代到弹幕服务
# - 可选：HTTPS（Let’s Encrypt）
#   - HTTP-01：无需 Cloudflare Token（但 CF 橙云建议临时灰云）
#   - DNS-01（Cloudflare）：无需灰云，可全程橙云（需要 CF API Token）
#
# 给别人用的场景：
# - 没域名：域名直接回车留空 -> 只装 HTTP（用 IP 访问）
# - 有域名：可选启用 HTTPS；如是 Cloudflare 可选自动创建 DNS 记录 + DNS-01 签证书
# =========================================

need_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "请用 root 执行：sudo -i 之后再运行脚本"
    exit 1
  fi
}

ask() {
  local prompt="$1"
  local default="${2:-}"
  local var
  if [ -n "$default" ]; then
    read -r -p "${prompt} (默认：${default})：" var
    echo "${var:-$default}"
  else
    read -r -p "${prompt}：" var
    echo "$var"
  fi
}

yesno() {
  local prompt="$1"
  local default="${2:-y}" # y/n
  local ans
  local hint="[y/n]"
  if [ "$default" = "y" ]; then hint="[Y/n]"; else hint="[y/N]"; fi
  read -r -p "${prompt} ${hint}：" ans
  ans="${ans,,}"
  if [ -z "$ans" ]; then ans="$default"; fi
  [ "$ans" = "y" ] || [ "$ans" = "yes" ]
}

detect_public_ip() {
  # 优先从外网服务探测；失败则返回空
  local ip=""
  ip="$(curl -fsS https://api.ipify.org 2>/dev/null || true)"
  if [ -z "$ip" ]; then
    ip="$(curl -fsS https://ifconfig.me 2>/dev/null || true)"
  fi
  echo "$ip"
}

install_basics() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y ca-certificates curl gnupg lsb-release ufw jq
}

install_docker() {
  if command -v docker >/dev/null 2>&1; then
    echo "Docker 已安装，跳过。"
    return
  fi
  echo "安装 Docker..."
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg

  local codename
  codename="$(. /etc/os-release && echo "$VERSION_CODENAME")"

  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${codename} stable" \
    > /etc/apt/sources.list.d/docker.list

  apt-get update -y
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  systemctl enable --now docker || true
}

run_danmu_container() {
  local image="$1"
  local cname="$2"
  local host_port="$3"
  local container_port="$4"

  echo "启动弹幕容器（幂等：会重建同名容器 ${cname}）..."
  docker rm -f "${cname}" >/dev/null 2>&1 || true
  docker run -d --name "${cname}" --restart unless-stopped \
    -p "${host_port}:${container_port}" \
    "${image}"
}

install_nginx() {
  apt-get install -y nginx
  systemctl enable --now nginx || true
}

write_nginx_http_proxy() {
  local domain="$1"   # 可能为空
  local upstream="$2"
  local site_name="$3"

  local server_name
  if [ -n "$domain" ]; then
    server_name="$domain"
  else
    server_name="_"
  fi

  cat >/etc/nginx/sites-available/${site_name} <<EOF
server {
    listen 80;
    server_name ${server_name};

    location / {
        proxy_pass ${upstream};

        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";

        proxy_connect_timeout 60s;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
        send_timeout 3600s;

        proxy_buffering off;
    }
}
EOF

  ln -sf /etc/nginx/sites-available/${site_name} /etc/nginx/sites-enabled/${site_name}
  rm -f /etc/nginx/sites-enabled/default || true

  nginx -t
  systemctl reload nginx
}

write_nginx_https_proxy() {
  local domain="$1"
  local upstream="$2"
  local site_name="$3"

  local live_dir="/etc/letsencrypt/live/${domain}"

  cat >/etc/nginx/sites-available/${site_name} <<EOF
server {
    listen 80;
    server_name ${domain};
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl http2;
    server_name ${domain};

    ssl_certificate     ${live_dir}/fullchain.pem;
    ssl_certificate_key ${live_dir}/privkey.pem;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers on;

    location / {
        proxy_pass ${upstream};

        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;

        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";

        proxy_connect_timeout 60s;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
        send_timeout 3600s;

        proxy_buffering off;
    }
}
EOF

  ln -sf /etc/nginx/sites-available/${site_name} /etc/nginx/sites-enabled/${site_name}
  rm -f /etc/nginx/sites-enabled/default || true

  nginx -t
  systemctl reload nginx
}

cf_upsert_a_record() {
  local token="$1"
  local zone_id="$2"
  local fqdn="$3"
  local ip="$4"
  local proxied="$5"  # true/false

  echo "Cloudflare：写入/更新 A 记录 ${fqdn} -> ${ip}（proxied=${proxied}）"

  # 查记录是否存在
  local resp record_id
  resp="$(curl -fsS -X GET "https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records?type=A&name=${fqdn}" \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json")"

  if [ "$(echo "$resp" | jq -r '.success')" != "true" ]; then
    echo "Cloudflare 查询失败："
    echo "$resp"
    return 1
  fi

  record_id="$(echo "$resp" | jq -r '.result[0].id // empty')"

  if [ -n "$record_id" ]; then
    # 更新
    resp="$(curl -fsS -X PUT "https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records/${record_id}" \
      -H "Authorization: Bearer ${token}" \
      -H "Content-Type: application/json" \
      --data "{\"type\":\"A\",\"name\":\"${fqdn}\",\"content\":\"${ip}\",\"ttl\":1,\"proxied\":${proxied}}")"
  else
    # 新建
    resp="$(curl -fsS -X POST "https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records" \
      -H "Authorization: Bearer ${token}" \
      -H "Content-Type: application/json" \
      --data "{\"type\":\"A\",\"name\":\"${fqdn}\",\"content\":\"${ip}\",\"ttl\":1,\"proxied\":${proxied}}")"
  fi

  if [ "$(echo "$resp" | jq -r '.success')" != "true" ]; then
    echo "Cloudflare 写入失败："
    echo "$resp"
    return 1
  fi

  echo "Cloudflare DNS 写入成功。"
}

le_http01() {
  local domain="$1"
  local email="$2"
  apt-get install -y certbot python3-certbot-nginx

  echo "开始 HTTP-01 申请证书..."
  echo "提示：如果你使用 Cloudflare 且当前是橙云，建议先临时改成灰云（DNS only），签完再改回橙云。"
  certbot --nginx -d "${domain}" --non-interactive --agree-tos -m "${email}" --redirect

  systemctl enable --now certbot.timer >/dev/null 2>&1 || true
}

le_dns01_cloudflare() {
  local domain="$1"
  local email="$2"
  local token="$3"

  apt-get install -y certbot python3-certbot-dns-cloudflare

  local cred_dir="/etc/letsencrypt"
  local cred_file="${cred_dir}/cloudflare.ini"
  mkdir -p "${cred_dir}"

  cat > "${cred_file}" <<EOF
dns_cloudflare_api_token = ${token}
EOF
  chmod 600 "${cred_file}"

  echo "开始 DNS-01(Cloudflare) 申请证书（无需灰云，可全程橙云）..."
  certbot certonly --dns-cloudflare --dns-cloudflare-credentials "${cred_file}" \
    -d "${domain}" --non-interactive --agree-tos -m "${email}" --keep-until-expiring

  # 续期后自动 reload nginx
  mkdir -p /etc/letsencrypt/renewal-hooks/deploy
  cat > /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh <<'EOF'
#!/usr/bin/env bash
systemctl reload nginx
EOF
  chmod +x /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh

  systemctl enable --now certbot.timer >/dev/null 2>&1 || true
}

main() {
  need_root
  echo "=============================="
  echo "Danmu 一键安装（可选 CF 自动DNS / 可选 HTTPS）"
  echo "=============================="

  local domain
  domain="$(ask "请输入域名（没有就直接回车，用 IP 访问）" "")"

  local danmu_port
  danmu_port="$(ask "弹幕服务宿主机端口（Nginx 反代到这个端口）" "8080")"

  local danmu_image
  danmu_image="$(ask "弹幕 Docker 镜像" "logvar/danmu-api:latest")"

  local danmu_cname
  danmu_cname="$(ask "弹幕容器名称" "danmu-api")"

  local danmu_container_port
  danmu_container_port="$(ask "弹幕容器内部端口（镜像暴露的端口）" "9321")"

  local upstream="http://127.0.0.1:${danmu_port}"
  local site_name="${domain:-danmu_ip_site}"

  # 可选：Cloudflare 自动 DNS
  local use_cf="n"
  local cf_token="" cf_zone_id="" cf_proxied="true" server_ip=""

  if [ -n "$domain" ]; then
    if yesno "是否使用 Cloudflare API 自动创建/更新 DNS A 记录？（需要 Token）" "n"; then
      use_cf="y"
      echo "请准备一个 Cloudflare API Token（建议权限：Zone:Read + DNS:Edit，仅限该域）"
      cf_token="$(ask "输入 Cloudflare API Token" "")"
      cf_zone_id="$(ask "输入 Cloudflare Zone ID（域名所在 Zone 的 ID）" "")"
      if yesno "A 记录是否开启橙云代理（Proxied）？" "y"; then
        cf_proxied="true"
      else
        cf_proxied="false"
      fi

      # IP：自动探测，探测不到则询问
      server_ip="$(detect_public_ip)"
      if [ -z "$server_ip" ]; then
        server_ip="$(ask "自动探测公网 IP 失败，请手动输入服务器公网 IP" "")"
      else
        server_ip="$(ask "探测到服务器公网 IP：${server_ip}，如需修改请输入新 IP" "${server_ip}")"
      fi
    fi
  fi

  # HTTPS 选择
  local enable_https="n"
  local email=""
  local https_mode="http01"  # http01 / dns01_cf

  if [ -n "$domain" ]; then
    if yesno "是否启用 HTTPS（Let's Encrypt）？" "y"; then
      enable_https="y"
      email="$(ask "请输入证书邮箱（Let's Encrypt）" "admin@${domain}")"

      if [ "$use_cf" = "y" ]; then
        if yesno "是否使用 DNS-01(Cloudflare) 签证书？（不需要灰云，推荐）" "y"; then
          https_mode="dns01_cf"
        else
          https_mode="http01"
        fi
      else
        https_mode="http01"
      fi
    fi
  fi

  echo
  echo "========= 配置预览 ========="
  echo "域名：${domain:-<无>（将用 IP 访问）}"
  echo "Upstream：${upstream}"
  echo "HTTPS：${enable_https}"
  [ -n "$email" ] && echo "证书邮箱：${email}"
  echo "镜像：${danmu_image}"
  echo "容器名：${danmu_cname}"
  echo "容器端口：${danmu_container_port} -> 宿主端口：${danmu_port}"
  if [ "$use_cf" = "y" ]; then
    echo "Cloudflare：自动DNS=是，ZoneID=${cf_zone_id}，proxied=${cf_proxied}，IP=${server_ip}"
  else
    echo "Cloudflare：自动DNS=否"
  fi
  if [ "$enable_https" = "y" ]; then
    echo "HTTPS 模式：${https_mode}"
  fi
  echo "==========================="
  echo

  install_basics
  install_docker

  # 启动弹幕
  run_danmu_container "${danmu_image}" "${danmu_cname}" "${danmu_port}" "${danmu_container_port}"

  # Nginx 反代（先写 HTTP，便于 http-01 或临时访问）
  install_nginx
  ufw allow 80/tcp || true
  ufw allow 443/tcp || true
  write_nginx_http_proxy "${domain}" "${upstream}" "${site_name}"

  # Cloudflare 自动写 DNS（若启用）
  if [ "$use_cf" = "y" ]; then
    cf_upsert_a_record "${cf_token}" "${cf_zone_id}" "${domain}" "${server_ip}" "${cf_proxied}"
    echo "提示：DNS 生效可能需要几十秒到几分钟。"
  fi

  # HTTPS
  if [ "$enable_https" = "y" ]; then
    if [ "$https_mode" = "dns01_cf" ]; then
      # DNS-01 不依赖 80 可访问，但需要域名解析到本机（可橙云）
      le_dns01_cloudflare "${domain}" "${email}" "${cf_token}"
    else
      # HTTP-01 依赖 80 可公网访问
      le_http01 "${domain}" "${email}"
    fi

    # 用 certonly 的场景，需要我们写 https server 块；certbot --nginx 的场景会自己改
    if [ "$https_mode" = "dns01_cf" ]; then
      write_nginx_https_proxy "${domain}" "${upstream}" "${site_name}"
    fi
  fi

  echo
  echo "========== 完成 =========="
  if [ -n "$domain" ]; then
    if [ "$enable_https" = "y" ]; then
      echo "管理页： https://${domain}/admin_888999"
      echo "普通：   https://${domain}/123987455"
    else
      echo "管理页： http://${domain}/admin_888999"
      echo "普通：   http://${domain}/123987455"
    fi
  else
    echo "你未填写域名：请用服务器 IP 访问："
    echo "  http://<你的服务器IP>/admin_888999"
    echo "  http://<你的服务器IP>/123987455"
    echo "（HTTPS 需要域名才能签 Let’s Encrypt）"
  fi
  echo "=========================="
}

main "$@"
