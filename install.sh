#!/usr/bin/env bash
# LogVar 弹幕 API · Docker 高级一键部署脚本
# 用法：
#   安装 / 更新：bash install.sh
#   卸载 / 清理：bash install.sh uninstall
#   查看状态：  bash install.sh status

set -e

### ============ 彩色输出函数 ============

COLOR_RESET="\e[0m"
COLOR_GREEN="\e[32m"
COLOR_YELLOW="\e[33m"
COLOR_RED="\e[31m"
COLOR_CYAN="\e[36m"

info()    { echo -e "${COLOR_CYAN}[INFO]${COLOR_RESET} $*"; }
success() { echo -e "${COLOR_GREEN}[OK]  ${COLOR_RESET} $*"; }
warn()    { echo -e "${COLOR_YELLOW}[WARN]${COLOR_RESET} $*"; }
error()   { echo -e "${COLOR_RED}[ERR] ${COLOR_RESET} $*"; }

### ============ 基本检查 ============

require_root() {
  if [[ $EUID -ne 0 ]]; then
    error "请使用 root 身份运行脚本（sudo bash install.sh）"
    exit 1
  fi
}

check_cmd() {
  command -v "$1" >/dev/null 2>&1
}

### ============ 安装 curl & Docker ============

install_curl() {
  if ! check_cmd curl; then
    info "正在安装 curl..."
    apt-get update -y
    apt-get install -y curl
    success "curl 安装完成"
  fi
}

install_docker() {
  if check_cmd docker; then
    success "检测到 Docker 已安装"
    return
  fi

  info "正在安装 Docker..."
  apt-get update -y
  apt-get install -y ca-certificates curl gnupg lsb-release

  install -m 0755 -d /etc/apt/keyrings
  if [ ! -f /etc/apt/keyrings/docker.gpg ]; then
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
      | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
  fi

  local codename
  codename="$(. /etc/os-release && echo "$VERSION_CODENAME")"

  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
    ${codename} stable" > /etc/apt/sources.list.d/docker.list

  apt-get update -y
  apt-get install -y docker-ce docker-ce-cli containerd.io

  systemctl enable docker
  systemctl start docker
  success "Docker 安装完成"
}

### ============ 公网 IP 检测 ============

detect_ipv4() {
  curl -4 -fsS ifconfig.co 2>/dev/null || \
  curl -4 -fsS icanhazip.com 2>/dev/null || \
  hostname -I 2>/dev/null | awk '{print $1}'
}

detect_ipv6() {
  curl -6 -fsS ifconfig.co 2>/dev/null || \
  curl -6 -fsS icanhazip.com 2>/dev/null || true
}

### ============ 端口占用检测 ============

ensure_port() {
  local port
  while true; do
    read -rp "请输入对外访问端口 [回车默认 8080]: " port
    port="${port:-8080}"

    if ! [[ "$port" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
      warn "端口无效，请输入 1-65535 的整数"
      continue
    fi

    if ss -tuln 2>/dev/null | grep -q ":$port "; then
      warn "端口 $port 已被占用"
      read -rp "仍然继续使用该端口？[y/N]: " yn
      case "$yn" in
        [Yy]*) ;;
        *) continue ;;
      esac
    fi

    PORT="$port"
    break
  done
}

### ============ 卸载 / 清理 ============

uninstall_all() {
  require_root
  info "开始卸载 danmu-api 及相关组件..."

  if docker ps -a --format '{{.Names}}' | grep -q '^danmu-api$'; then
    info "停止并删除 danmu-api 容器..."
    docker stop danmu-api >/dev/null 2>&1 || true
    docker rm danmu-api >/dev/null 2>&1 || true
  fi

  if docker ps -a --format '{{.Names}}' | grep -q '^watchtower-danmu-api$'; then
    info "停止并删除 Watchtower 容器..."
    docker stop watchtower-danmu-api >/dev/null 2>&1 || true
    docker rm watchtower-danmu-api >/dev/null 2>&1 || true
  fi

  if docker images --format '{{.Repository}}:{{.Tag}}' | grep -q '^logyar/danmu-api:'; then
    read -rp "是否删除 danmu-api 镜像？[y/N]: " yn
    case "$yn" in
      [Yy]*)
        docker rmi logyar/danmu-api:latest >/dev/null 2>&1 || true
        ;;
    esac
  fi

  rm -f .env.danmu-api docker-compose.danmu-api.yml README_danmu-api.txt

  success "卸载 / 清理完成"
  exit 0
}

### ============ 状态查看 ============

show_status() {
  info "当前 Docker 容器状态："
  docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}' \
    | sed 's/^/  /'
  echo
  info "如需查看日志：docker logs -f danmu-api"
  exit 0
}

### ============ 主安装流程 ============

install_all() {
  require_root
  install_curl
  install_docker

  echo "====================================================="
  echo "      LogVar 弹幕 API · Docker 高级一键部署脚本"
  echo "====================================================="
  echo

  # ==== 交互参数 ====
  echo -e "${COLOR_CYAN}输入参数配置（回车使用方括号中的默认值）${COLOR_RESET}"

  ensure_port
  echo

  read -rp "请输入普通访问 TOKEN [默认: 123987456]: " TOKEN
  TOKEN="${TOKEN:-123987456}"

  read -rp "请输入管理访问 ADMIN_TOKEN [默认: admin_888999]: " ADMIN_TOKEN
  ADMIN_TOKEN="${ADMIN_TOKEN:-admin_888999}"

  echo
  echo "请选择弹幕颜色转换模式 (CONVERT_COLOR)："
  echo "  1) default  - 不转换弹幕颜色"
  echo "  2) white    - 将所有非白色弹幕转换为白色"
  echo "  3) color    - 将所有白色弹幕转换为随机颜色（含白色，白色概率较高）"
  local color_choice
  while true; do
    read -rp "请输入数字 [1-3，默认 3]: " color_choice
    color_choice="${color_choice:-3}"
    case "$color_choice" in
      1) CONVERT_COLOR="default"; break ;;
      2) CONVERT_COLOR="white";   break ;;
      3) CONVERT_COLOR="color";   break ;;
      *) warn "无效选择，请输入 1/2/3";;
    esac
  done

  echo
  local auto_update_choice
  while true; do
    read -rp "是否开启 Watchtower 自动更新（每天 04:00 检查新镜像）？[Y/n]: " auto_update_choice
    auto_update_choice="${auto_update_choice:-Y}"
    case "$auto_update_choice" in
      [Yy]*) AUTO_UPDATE="1"; break ;;
      [Nn]*) AUTO_UPDATE="0"; break ;;
      *) warn "请输入 Y 或 N" ;;
    esac
  done

  echo
  echo "=============== 配置确认 ==============="
  echo "  访问端口(Port):      ${PORT}"
  echo "  TOKEN:              ${TOKEN}"
  echo "  ADMIN_TOKEN:        ${ADMIN_TOKEN}"
  echo "  CONVERT_COLOR:      ${CONVERT_COLOR}"
  echo "  自动更新(AUTO_UPDATE): $( [ "$AUTO_UPDATE" = "1" ] && echo 已启用 || echo 已关闭 )"
  echo "======================================="
  read -rp "确认以上配置无误？[Y/n]: " confirm
  confirm="${confirm:-Y}"
  case "$confirm" in
    [Yy]*) ;;
    *) warn "用户取消安装"; exit 1 ;;
  esac

  # ==== 写入 .env ====
  cat > .env.danmu-api <<EOF
# danmu-api 部署配置备份（可用于 docker-compose 或迁移）
PORT=${PORT}
TOKEN=${TOKEN}
ADMIN_TOKEN=${ADMIN_TOKEN}
CONVERT_COLOR=${CONVERT_COLOR}
AUTO_UPDATE=${AUTO_UPDATE}
EOF

  success "已生成配置文件 .env.danmu-api"

  # ==== 生成 docker-compose 示例 ====
  cat > docker-compose.danmu-api.yml <<EOF
version: '3.8'

services:
  danmu-api:
    image: logyar/danmu-api:latest
    container_name: danmu-api
    restart: unless-stopped
    ports:
      - "\${PORT:-8080}:8080"
    environment:
      - TOKEN=\${TOKEN}
      - ADMIN_TOKEN=\${ADMIN_TOKEN}
      - CONVERT_COLOR=\${CONVERT_COLOR}
    healthcheck:
      test: ["CMD-SHELL","curl -fs http://127.0.0.1:8080/\${TOKEN} || exit 1"]
      interval: 30s
      timeout: 5s
      retries: 3
EOF

  success "已生成 docker-compose.danmu-api.yml（仅示例，不会自动执行 compose）"

  # ==== 停掉旧容器 ====
  if docker ps -a --format '{{.Names}}' | grep -q '^danmu-api$'; then
    info "发现已有 danmu-api 容器，先停止并删除..."
    docker stop danmu-api >/dev/null 2>&1 || true
    docker rm danmu-api >/dev/null 2>&1 || true
  fi

  if docker ps -a --format '{{.Names}}' | grep -q '^watchtower-danmu-api$'; then
    info "发现已有 Watchtower 容器，先停止并删除..."
    docker stop watchtower-danmu-api >/dev/null 2>&1 || true
    docker rm watchtower-danmu-api >/dev/null 2>&1 || true
  fi

  # ==== 拉取镜像并启动容器 ====
  info "拉取 danmu-api 最新镜像..."
  docker pull logyar/danmu-api:latest

  info "启动 danmu-api 容器..."
  docker run -d \
    --name danmu-api \
    --restart unless-stopped \
    -p "${PORT}:8080" \
    -e "TOKEN=${TOKEN}" \
    -e "ADMIN_TOKEN=${ADMIN_TOKEN}" \
    -e "CONVERT_COLOR=${CONVERT_COLOR}" \
    --health-cmd="curl -fs http://127.0.0.1:8080/${TOKEN} || exit 1" \
    --health-interval=30s \
    --health-timeout=5s \
    --health-retries=3 \
    logyar/danmu-api:latest >/dev/null

  success "danmu-api 容器已启动"

  # ==== Watchtower 自动更新 ====
  if [ "$AUTO_UPDATE" = "1" ]; then
    info "启动 Watchtower（每天 04:00 检查 danmu-api 镜像更新）..."
    docker run -d \
      --name watchtower-danmu-api \
      --restart unless-stopped \
      -v /var/run/docker.sock:/var/run/docker.sock \
      containrrr/watchtower \
      --cleanup \
      --schedule "0 0 4 * * *" \
      danmu-api >/dev/null
    success "Watchtower 已启动"
  fi

  # ==== 生成 README 使用说明 ====
  local ipv4 ipv6
  ipv4="$(detect_ipv4)"
  ipv6="$(detect_ipv6)"

  cat > README_danmu-api.txt <<EOF
LogVar 弹幕 API 部署成功说明
================================

一、访问地址
-----------------------------

普通访问（TOKEN）：
  IPv4: http://${ipv4:-你的服务器IP}:${PORT}/${TOKEN}
EOF

  if [ -n "$ipv6" ]; then
    cat >> README_danmu-api.txt <<EOF
  IPv6: http://[${ipv6}]:${PORT}/${TOKEN}
EOF
  fi

  cat >> README_danmu-api.txt <<EOF

管理访问（ADMIN_TOKEN）：
  IPv4: http://${ipv4:-你的服务器IP}:${PORT}/${ADMIN_TOKEN}
EOF

  if [ -n "$ipv6" ]; then
    cat >> README_danmu-api.txt <<EOF
  IPv6: http://[${ipv6}]:${PORT}/${ADMIN_TOKEN}
EOF
  fi

  cat >> README_danmu-api.txt <<'EOF'

二、常用 Docker 命令
-----------------------------

查看容器：
  docker ps

查看日志：
  docker logs -f danmu-api

重启服务：
  docker restart danmu-api

停止服务：
  docker stop danmu-api

如果启用了自动更新（Watchtower），相关命令：
  查看日志：
    docker logs -f watchtower-danmu-api

  停止自动更新：
    docker stop watchtower-danmu-api && docker rm watchtower-danmu-api


三、配置文件说明
-----------------------------

1) .env.danmu-api
   - 记录了当前使用的 PORT / TOKEN / ADMIN_TOKEN / CONVERT_COLOR / AUTO_UPDATE
   - 方便后续迁移、备份、或使用 docker-compose 管理

2) docker-compose.danmu-api.yml
   - 一个可选的 docker-compose 示例文件
   - 如需使用：
       export $(grep -v '^#' .env.danmu-api | xargs)
       docker compose -f docker-compose.danmu-api.yml up -d

四、安全加固建议（可选）
-----------------------------

1) 如需给管理端再加一层 Basic Auth：
   - 建议在服务器上再部署 Nginx / Caddy 等反向代理
   - 仅对 /${ADMIN_TOKEN} 这个路径启用 Basic Auth
   - 反向代理再转发到本机的 http://127.0.0.1:${PORT}/${ADMIN_TOKEN}

2) 如需 HTTPS：
   - 准备一个域名解析到本服务器
   - 在反向代理（Nginx / Caddy / Nginx Proxy Manager 等）上签发证书
   - 再把域名访问转发到本机 http://127.0.0.1:${PORT}

EOF

  success "已生成 README_danmu-api.txt 使用说明"

  # ==== 最终信息输出 ====
  ipv4="$(detect_ipv4)"

  echo
  echo "=============================================================="
  echo "                      部署完成！"
  echo "=============================================================="
  echo
  echo -e "${COLOR_GREEN}普通访问（TOKEN）地址：${COLOR_RESET}"
  echo "  http://${ipv4:-你的服务器IP}:${PORT}/${TOKEN}"
  echo
  echo -e "${COLOR_GREEN}管理访问（ADMIN_TOKEN）地址：${COLOR_RESET}"
  echo "  http://${ipv4:-你的服务器IP}:${PORT}/${ADMIN_TOKEN}"
  echo
  echo "当前配置："
  echo "  PORT           = ${PORT}"
  echo "  TOKEN          = ${TOKEN}"
  echo "  ADMIN_TOKEN    = ${ADMIN_TOKEN}"
  echo "  CONVERT_COLOR  = ${CONVERT_COLOR}"
  echo "  AUTO_UPDATE    = ${AUTO_UPDATE}  ($( [ "$AUTO_UPDATE" = "1" ] && echo 已启用 || echo 已关闭 ))"
  echo
  echo "常用命令："
  echo "  查看状态：   docker ps"
  echo "  查看日志：   docker logs -f danmu-api"
  echo "  重启服务：   docker restart danmu-api"
  echo "  停止服务：   docker stop danmu-api"
  if [ "$AUTO_UPDATE" = "1" ]; then
    echo "  查看更新日志：docker logs -f watchtower-danmu-api"
  fi
  echo
  echo "配置/说明文件："
  echo "  .env.danmu-api"
  echo "  docker-compose.danmu-api.yml"
  echo "  README_danmu-api.txt"
  echo
  echo "如需卸载 / 清理：bash $(basename "$0") uninstall"
  echo "=============================================================="
}

### ============ 主入口 ============

case "$1" in
  uninstall)
    uninstall_all
    ;;
  status)
    show_status
    ;;
  *)
    install_all
    ;;
esac
