#!/usr/bin/env bash
set -euo pipefail

# ==========================================================
# Danmu 一键安装（通用版 / 反代默认开启 / 可选 Cloudflare / 可选 HTTPS）
# 适用：Debian 11/12、Ubuntu 20.04/22.04/24.04（建议 root 执行）
#
# 需求已内置：
# - 默认启用 Nginx 反代（80/443 -> 弹幕端口）
# - 开头检测到“已安装/已存在”会先清理【弹幕相关】再重装（不动其它容器/站点）
# - 交互项完整：端口、镜像、容器名、容器内端口、Token、管理员 Token、CF DNS、HTTPS 模式
# - 结束生成 Summary TXT：/root/danmu_install_summary.txt（并打印）
#
# 注意：
# - “清理”只清理本脚本涉及的对象（指定容器名、对应 nginx 站点、该域名证书目录等）
#   不会删除你服务器上其它 Docker 容器/镜像（更安全）。
# ==========================================================

need_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "请用 root 执行：sudo -i 后再运行"
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
  local ans hint
  if [ "$default" = "y" ]; then hint="[Y/n]"; else hint="[y/N]"; fi
  read -r -p "${prompt} ${hint}：" ans
  ans="${ans,,}"
  if [ -z "$ans" ]; then ans="$default"; fi
  [ "$ans" = "y" ] || [ "$ans" = "yes" ]
}

detect_os() {
  . /etc/os-release
  echo "${ID}|${VERSION_CODENAME}"
}

detect_public_ip() {
  local ip=""
  ip="$(curl -fsS https://api.ipify.org 2>/dev/null || true)"
  if [ -z "$ip" ]; then ip="$(curl -fsS https://ifconfig.me 2>/dev/null || true)"; fi
  echo "$ip"
}

install_basics() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y ca-certificates curl gnupg lsb-release jq ufw
}

install_docker() {
  if command -v docker >/dev/null 2>&1; then
    echo "Docker 已安装，跳过安装步骤。"
    systemctl enable --now docker >/dev/null 2>&1 || true
    return
  fi

  local os_id codename
  IFS="|" read -r os_id codename < <(detect_os)

  echo "检测到系统：${os_id} / ${codename}"
  echo "开始安装 Docker（按系统自动选择官方仓库）..."

  install -m 0755 -d /etc/apt/keyrings

  if [ "$os_id" = "debian" ]; then
    curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian ${codename} stable"       > /etc/apt/sources.list.d/docker.list
  elif [ "$os_id" = "ubuntu" ]; then
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${codename} stable"       > /etc/apt/sources.list.d/docker.list
  else
    echo "不支持的系统：${os_id}. 仅支持 Debian/Ubuntu。"
    exit 1
  fi

  apt-get update -y
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
  systemctl enable --now docker >/dev/null 2>&1 || true
}

install_nginx() {
  apt-get install -y nginx
  systemctl enable --now nginx >/dev/null 2>&1 || true
  ufw allow 80/tcp >/dev/null 2>&1 || true
  ufw allow 443/tcp >/dev/null 2>&1 || true
}

cleanup_danmu_related() {
  local cname="$1"
  local site_name="$2"
  local domain="${3:-}"

  echo "开始清理（仅清理弹幕相关对象）..."

  if command -v docker >/dev/null 2>&1; then
    if docker ps -a --format '{{.Names}}' | grep -qx "${cname}"; then
      echo "清理容器：${cname}"
      docker rm -f "${cname}" >/dev/null 2>&1 || true
    fi
  fi

  if [ -n "${site_name}" ]; then
    rm -f "/etc/nginx/sites-enabled/${site_name}" || true
    rm -f "/etc/nginx/sites-available/${site_name}" || true
  fi

  if [ -n "$domain" ]; then
    rm -rf "/etc/letsencrypt/live/${domain}" "/etc/letsencrypt/archive/${domain}" "/etc/letsencrypt/renewal/${domain}.conf" >/dev/null 2>&1 || true
  fi

  nginx -t >/dev/null 2>&1 && systemctl reload nginx >/dev/null 2>&1 || true
  echo "清理完成。"
}

run_danmu_container() {
  local image="$1"
  local cname="$2"
  local host_port="$3"
  local container_port="$4"

  echo "启动弹幕容器（会重建同名容器：${cname}）..."
  docker rm -f "${cname}" >/dev/null 2>&1 || true
  docker run -d --name "${cname}" --restart unless-stopped     -p "${host_port}:${container_port}"     "${image}"
}

write_nginx_http_proxy() {
  local domain="$1"
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
  local proxied="$5"

  echo "Cloudflare：写入/更新 A 记录 ${fqdn} -> ${ip}（proxied=${proxied}）"

  local resp record_id
  resp="$(curl -fsS -X GET "https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records?type=A&name=${fqdn}"     -H "Authorization: Bearer ${token}"     -H "Content-Type: application/json")"

  if [ "$(echo "$resp" | jq -r '.success')" != "true" ]; then
    echo "Cloudflare 查询失败："
    echo "$resp"
    return 1
  fi

  record_id="$(echo "$resp" | jq -r '.result[0].id // empty')"

  if [ -n "$record_id" ]; then
    resp="$(curl -fsS -X PUT "https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records/${record_id}"       -H "Authorization: Bearer ${token}"       -H "Content-Type: application/json"       --data "{"type":"A","name":"${fqdn}","content":"${ip}","ttl":1,"proxied":${proxied}}")"
  else
    resp="$(curl -fsS -X POST "https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records"       -H "Authorization: Bearer ${token}"       -H "Content-Type: application/json"       --data "{"type":"A","name":"${fqdn}","content":"${ip}","ttl":1,"proxied":${proxied}}")"
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
  echo "提示：若 Cloudflare 橙云导致验证失败，请临时改灰云（DNS only），签完再改回橙云。"
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

  echo "开始 DNS-01(Cloudflare) 申请证书（无需灰云）..."
  certbot certonly --dns-cloudflare --dns-cloudflare-credentials "${cred_file}"     -d "${domain}" --non-interactive --agree-tos -m "${email}" --keep-until-expiring

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
  echo "Danmu 一键安装（反代默认开启 / 可选 CF / 可选 HTTPS）"
  echo "=============================="

  local domain
  domain="$(ask "请输入域名（没有就直接回车；仍会启用 Nginx，用 IP 访问）" "")"

  local danmu_port
  danmu_port="$(ask "弹幕服务宿主机端口（Docker 对外端口；Nginx 反代到它）" "8080")"

  local danmu_image
  danmu_image="$(ask "弹幕 Docker 镜像" "logvar/danmu-api:latest")"

  local danmu_cname
  danmu_cname="$(ask "弹幕容器名称" "danmu-api")"

  local danmu_container_port
  danmu_container_port="$(ask "弹幕容器内部端口（镜像暴露端口）" "9321")"

  local public_token admin_token
  public_token="$(ask "普通访问 Token（路径用，例如 /123987455）" "123987455")"
  admin_token="$(ask "管理员 Token（路径用，例如 /admin_888999；无需写前缀 admin_）" "888999")"

  local upstream="http://127.0.0.1:${danmu_port}"
  local site_name="${domain:-danmu_ip_site}"

  local use_cf="n"
  local cf_token="" cf_zone_id="" cf_proxied="true" server_ip=""
  local hide_ip_output="y"
  if [ -n "$domain" ] && yesno "是否使用 Cloudflare API 自动创建/更新 DNS A 记录？（需要 Token）" "n"; then
    use_cf="y"
    echo "建议 Token 权限：Zone:Read + DNS:Edit（仅限该域）"
    cf_token="$(ask "输入 Cloudflare API Token" "")"
    cf_zone_id="$(ask "输入 Cloudflare Zone ID（概览里“区域ID/Zone ID”那串）" "")"
    if yesno "A 记录是否开启橙云代理（Proxied）？" "y"; then

    local hide_ip_output="y"
    if yesno "是否在脚本输出/总结里隐藏服务器真实IP？（推荐）" "y"; then
      hide_ip_output="y"
    else
      hide_ip_output="n"
    fi
      cf_proxied="true"
    else
      cf_proxied="false"
    fi

    server_ip="$(ask "Cloudflare DNS A 记录要指向的服务器公网 IP（建议填你的服务器IP；留空则自动探测，但不会回显）" "")"
    if [ -z "$server_ip" ]; then
      server_ip="$(detect_public_ip)"
    fi
    if [ -z "$server_ip" ]; then
      server_ip="$(ask "自动探测公网 IP 失败，请手动输入服务器公网 IP" "")"
    fi
    fi
  fi

  local enable_https="n"
  local email=""
  local https_mode="http01"
  if [ -n "$domain" ] && yesno "是否启用 HTTPS（Let's Encrypt）？" "y"; then
    enable_https="y"
    email="$(ask "请输入证书邮箱（Let's Encrypt）" "admin@${domain}")"
    if [ "$use_cf" = "y" ] && yesno "是否使用 DNS-01(Cloudflare) 签证书？（推荐：不需要灰云）" "y"; then
      https_mode="dns01_cf"
    else
      https_mode="http01"
    fi
  fi

  echo
  echo "========= 配置预览 ========="
  echo "域名：${domain:-<无>（用 IP 访问）}"
  echo "Upstream：${upstream}"
  echo "Nginx：启用（80/443）"
  echo "HTTPS：${enable_https}"
  [ -n "$email" ] && echo "证书邮箱：${email}"
  echo "镜像：${danmu_image}"
  echo "容器名：${danmu_cname}"
  echo "容器端口：${danmu_container_port} -> 宿主端口：${danmu_port}"
  echo "普通 Token：/${public_token}"
  echo "管理员 Token：/admin_${admin_token}"
  if [ "$use_cf" = "y" ]; then
    if [ "${hide_ip_output:-y}" = "y" ]; then
      echo "Cloudflare：自动DNS=是，ZoneID=${cf_zone_id}，proxied=${cf_proxied}，IP=<hidden>"
    else
      echo "Cloudflare：自动DNS=是，ZoneID=${cf_zone_id}，proxied=${cf_proxied}，IP=${server_ip}"
    fi
  else
    echo "Cloudflare：自动DNS=否"
  fi
  if [ "$enable_https" = "y" ]; then
    echo "HTTPS 模式：${https_mode}"
  fi
  echo "==========================="
  echo

  install_basics
  install_nginx
  cleanup_danmu_related "${danmu_cname}" "${site_name}" "${domain}"
  install_docker

  run_danmu_container "${danmu_image}" "${danmu_cname}" "${danmu_port}" "${danmu_container_port}"

  write_nginx_http_proxy "${domain}" "${upstream}" "${site_name}"

  if [ "$use_cf" = "y" ]; then
    cf_upsert_a_record "${cf_token}" "${cf_zone_id}" "${domain}" "${server_ip}" "${cf_proxied}"
    echo "提示：DNS 生效可能需要几十秒到几分钟。"
  fi

  if [ "$enable_https" = "y" ]; then
    if [ "$https_mode" = "dns01_cf" ]; then
      le_dns01_cloudflare "${domain}" "${email}" "${cf_token}"
      write_nginx_https_proxy "${domain}" "${upstream}" "${site_name}"
    else
      le_http01 "${domain}" "${email}"
    fi
  fi

  local ip
  ip="$(detect_public_ip)"
  [ -z "$ip" ] && ip="<你的服务器公网IP>"

  local proto="http"
  if [ "$enable_https" = "y" ]; then proto="https"; fi

  local summary="/root/danmu_install_summary.txt"
  {
    echo "Danmu 安装总结"
    echo "生成时间：$(date -Is)"
    echo
    echo "基础参数："
    echo "  系统：$(. /etc/os-release && echo "$PRETTY_NAME")"
    if [ "${hide_ip_output:-y}" = "y" ]; then
      echo "  公网IP：<hidden>"
    else
      echo "  公网IP：${ip}"
    fi
    echo "  域名：${domain:-<无>}"
    echo "  Nginx：启用（对外端口 80/443）"
    echo "  Upstream：${upstream}"
    echo "  Docker 镜像：${danmu_image}"
    echo "  容器名：${danmu_cname}"
    echo "  Docker 映射：${danmu_port}:${danmu_container_port}"
    echo
    echo "访问地址（你要的格式）："
    if [ -n "$domain" ]; then
      echo "  普通： ${proto}://${domain}/${public_token}"
      echo "  管理： ${proto}://${domain}/admin_${admin_token}"
    else
      echo "  普通： http://${ip}:80/${public_token}"
      echo "        http://${ip}/${public_token}"
      echo "  管理： http://${ip}:80/admin_${admin_token}"
      echo "        http://${ip}/admin_${admin_token}"
    fi
    echo
    if [ "$use_cf" = "y" ]; then
      echo "Cloudflare："
      echo "  Zone ID：${cf_zone_id}"
      echo "  Proxied：${cf_proxied}"
      if [ "${hide_ip_output:-y}" = "y" ]; then
        echo "  A 记录：${domain} -> <hidden>"
      else
        echo "  A 记录：${domain} -> ${server_ip}"
      fi
    fi
    if [ "$enable_https" = "y" ]; then
      echo "HTTPS："
      echo "  邮箱：${email}"
      echo "  模式：${https_mode}"
    fi
  } | tee "$summary"

  echo
  echo "========== 完成 =========="
  echo "Summary 已写入：${summary}"
  echo "=========================="
}

main "$@"
