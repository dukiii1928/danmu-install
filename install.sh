#!/usr/bin/env bash
# LogVar 弹幕 API · Docker 一键部署脚本
# 用法：
#   安装/更新：bash install.sh
#   卸载：    bash install.sh uninstall
#   状态：    bash install.sh status

set -e

#################### 基本默认配置 ####################

# 持久化 .env 的目录 / 文件（挂载到容器 /app/config/.env，兼容 1.9.2+ 新配置目录）
DANMU_ENV_DIR="/root/danmu-config"
DANMU_ENV_FILE="${DANMU_ENV_DIR}/.env"

# 默认 VOD 相关配置（与后台默认一致）
DEFAULT_SOURCE_ORDER="360,vod,douban,tencent,youku,iqiyi,imgo,bilibili,renren,hanjutv,bahamut,dandan"
DEFAULT_OTHER_SERVER="https://api.danmu.icu"
DEFAULT_VOD_SERVERS="zy@https://zy.jinchancaiji.com,789@https://www.caiji.cyou,听风@https://gctf.tfdh.top"
DEFAULT_VOD_RETURN_MODE="fastest"
DEFAULT_VOD_REQUEST_TIMEOUT="10000"
DEFAULT_YOUKU_CONCURRENCY="8"

# 主镜像
IMAGE_NAME="logvar/danmu-api:latest"

#################### 彩色输出 ####################

COLOR_RESET="\e[0m"
COLOR_GREEN="\e[32m"
COLOR_YELLOW="\e[33m"
COLOR_RED="\e[31m"
COLOR_CYAN="\e[36m"

info()    { echo -e "${COLOR_CYAN}[INFO]${COLOR_RESET} $*"; }
success() { echo -e "${COLOR_GREEN}[OK]  ${COLOR_RESET} $*"; }
warn()    { echo -e "${COLOR_YELLOW}[WARN]${COLOR_RESET} $*"; }
error()   { echo -e "${COLOR_RED}[ERR] ${COLOR_RESET} $*"; }

#################### 基础检查 ####################

require_root() {
  if [[ $EUID -ne 0 ]]; then
    error "请用 root 运行（sudo bash install.sh）"
    exit 1
  fi
}

check_cmd() {
  command -v "$1" >/dev/null 2>&1
}

install_curl() {
  if ! check_cmd curl; then
    info "安装 curl..."
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

  info "安装 Docker..."

  apt-get update -y
  apt-get install -y ca-certificates curl gnupg lsb-release

  install -m 0755 -d /etc/apt/keyrings
  if [ ! -f /etc/apt/keyrings/docker.gpg ]; then
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
      | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
  fi

  . /etc/os-release
  case "$ID" in
    debian) docker_distro="debian" ;;
    ubuntu) docker_distro="ubuntu" ;;
    *) docker_distro="ubuntu"
       warn "未知系统 ID=${ID}，按 ubuntu 源配置 Docker，如有问题请手动修改 /etc/apt/sources.list.d/docker.list"
       ;;
  esac

  codename="${VERSION_CODENAME}"

  cat > /etc/apt/sources.list.d/docker.list <<EOF
deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/${docker_distro} ${codename} stable
EOF

  apt-get update -y
  apt-get install -y docker-ce docker-ce-cli containerd.io

  systemctl enable docker
  systemctl start docker
  success "Docker 安装完成"
}

detect_ipv4() {
  curl -4 -fsS ifconfig.co 2>/dev/null || \
  curl -4 -fsS icanhazip.com 2>/dev/null || \
  hostname -I 2>/dev/null | awk '{print $1}'
}

#################### 端口交互 ####################

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
      yn="${yn:-N}"
      case "$yn" in
        [Yy]*) ;;
        *) continue ;;
      esac
    fi

    PORT="$port"
    break
  done
}

#################### 卸载 & 状态 ####################

uninstall_all() {
  require_root
  info "卸载 danmu-api 相关容器..."

  for name in \
    danmu-api \
    dannu-api \
    watchtower \
    watchtower-danmu-api \
    watchtower-dannu-api \
    danmu-watchtower; do
    if docker ps -a --format '{{.Names}}' | grep -q "^${name}$"; then
      info "停止并删除容器 ${name}..."
      docker stop "$name" >/dev/null 2>&1 || true
      docker rm "$name" >/dev/null 2>&1 || true
    fi
  done

  rm -f .env.danmu-api docker-compose.danmu-api.yml README_danmu-api.txt
  # 是否删除持久化 .env 根据自己需求，这里保留方便下次用
  success "卸载完成"
  exit 0
}

show_status() {
  info "当前 Docker 容器状态："
  docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}' \
    | sed 's/^/  /'
  echo
  info "查看日志：docker logs -f danmu-api"
  exit 0
}

#################### 主安装流程 ####################

install_all() {
  require_root
  install_curl
  install_docker

  mkdir -p "${DANMU_ENV_DIR}"
  touch "${DANMU_ENV_FILE}"

  echo "====================================================="
  echo "      LogVar 弹幕 API · Docker 一键部署脚本"
  echo "====================================================="
  echo
  echo -e "${COLOR_CYAN}只会询问：端口 / TOKEN / ADMIN_TOKEN / 自动更新 / CONVERT_COLOR / BILIBILI_COOKIE${COLOR_RESET}"
  echo

  # 0. 清理旧容器
  info "检查并清理已有旧容器（如有）..."
  for name in \
    danmu-api \
    dannu-api \
    watchtower \
    watchtower-danmu-api \
    watchtower-dannu-api \
    danmu-watchtower; do
    if docker ps -a --format '{{.Names}}' | grep -q "^${name}$"; then
      info "发现旧容器 ${name}，正在停止并删除..."
      docker stop "$name" >/dev/null 2>&1 || true
      docker rm "$name" >/dev/null 2>&1 || true
    fi
  done
  success "旧容器清理完成"

  # 1. 端口
  ensure_port
  echo

  # 2. TOKEN
  read -rp "请输入普通访问 TOKEN [默认: 123987456]: " TOKEN
  TOKEN="${TOKEN:-123987456}"

  # 3. ADMIN_TOKEN
  read -rp "请输入管理访问 ADMIN_TOKEN [默认: admin_888999]: " ADMIN_TOKEN
  ADMIN_TOKEN="${ADMIN_TOKEN:-admin_888999}"

  echo
  # 4. 弹幕颜色模式
  echo "请选择弹幕颜色转换模式 (CONVERT_COLOR)："
  echo "  1) default  - 不转换弹幕颜色"
  echo "  2) white    - 全部变成白色"
  echo "  3) color    - 白色弹幕变随机颜色（推荐）"
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
  # 5. 自动更新
  local auto_update_choice
  while true; do
    read -rp "是否启用 Watchtower 自动更新镜像？[Y/n]: " auto_update_choice
    auto_update_choice="${auto_update_choice:-Y}"
    case "$auto_update_choice" in
      [Yy]*) AUTO_UPDATE="1"; break ;;
      [Nn]*) AUTO_UPDATE="0"; break ;;
      *) warn "请输入 Y 或 N" ;;
    esac
  done

  echo
  # 6. B 站 Cookie
  read -rp "请输入 BILIBILI_COOKIE（可留空，直接粘贴整串 Cookie）: " BILIBILI_COOKIE

  # 其他全部使用默认值
  SOURCE_ORDER="${DEFAULT_SOURCE_ORDER}"
  OTHER_SERVER="${DEFAULT_OTHER_SERVER}"
  VOD_SERVERS="${DEFAULT_VOD_SERVERS}"
  VOD_RETURN_MODE="${DEFAULT_VOD_RETURN_MODE}"
  VOD_REQUEST_TIMEOUT="${DEFAULT_VOD_REQUEST_TIMEOUT}"
  YOUKU_CONCURRENCY="${DEFAULT_YOUKU_CONCURRENCY}"

  echo
  echo "=============== 配置确认 ==============="
  echo "  访问端口(Port):        ${PORT}"
  echo "  TOKEN:                ${TOKEN}"
  echo "  ADMIN_TOKEN:          ${ADMIN_TOKEN}"
  echo "  CONVERT_COLOR:        ${CONVERT_COLOR}"
  echo "  自动更新(AUTO_UPDATE): $( [ "$AUTO_UPDATE" = "1" ] && echo 已启用 || echo 已关闭 )"
  [ -n "$BILIBILI_COOKIE" ] && echo "  BILIBILI_COOKIE:      (已设置，长度 ${#BILIBILI_COOKIE})" || echo "  BILIBILI_COOKIE:      未设置"
  echo "======================================="
  read -rp "确认以上配置无误？[Y/n]: " confirm
  confirm="${confirm:-Y}"
  case "$confirm" in
    [Yy]*) ;;
    *) warn "用户取消安装"; exit 1 ;;
  esac

  ######## 写入备份 & .env（重点） ########

  # 1）备份一份完整配置，方便以后查看
  cat > .env.danmu-api <<EOF
PORT=${PORT}
TOKEN=${TOKEN}
ADMIN_TOKEN=${ADMIN_TOKEN}
CONVERT_COLOR=${CONVERT_COLOR}
AUTO_UPDATE=${AUTO_UPDATE}
SOURCE_ORDER=${SOURCE_ORDER}
OTHER_SERVER=${OTHER_SERVER}
VOD_SERVERS=${VOD_SERVERS}
VOD_RETURN_MODE=${VOD_RETURN_MODE}
VOD_REQUEST_TIMEOUT=${VOD_REQUEST_TIMEOUT}
YOUKU_CONCURRENCY=${YOUKU_CONCURRENCY}
BILIBILI_COOKIE=${BILIBILI_COOKIE}
DANMU_ENV_FILE=${DANMU_ENV_FILE}
EOF
  success "已生成配置备份 .env.danmu-api"

  # 2）生成运行时 .env（容器 /app/config/.env 实际读取的就是这个，1.9.2+）
  cat > "${DANMU_ENV_FILE}" <<EOF
TOKEN=${TOKEN}
ADMIN_TOKEN=${ADMIN_TOKEN}
CONVERT_COLOR=${CONVERT_COLOR}
SOURCE_ORDER=${SOURCE_ORDER}
OTHER_SERVER=${OTHER_SERVER}
VOD_SERVERS=${VOD_SERVERS}
VOD_RETURN_MODE=${VOD_RETURN_MODE}
VOD_REQUEST_TIMEOUT=${VOD_REQUEST_TIMEOUT}
YOUKU_CONCURRENCY=${YOUKU_CONCURRENCY}
BILIBILI_COOKIE=${BILIBILI_COOKIE}
EOF
  success "已生成运行时 .env 文件：${DANMU_ENV_FILE}"

  ######## docker-compose 示例 ########

  cat > docker-compose.danmu-api.yml <<EOF
version: '3.8'

services:
  danmu-api:
    image: ${IMAGE_NAME}
    container_name: danmu-api
    restart: unless-stopped
    ports:
      - "\${PORT:-8080}:9321"
    environment:
      - TOKEN=\${TOKEN}
      - ADMIN_TOKEN=\${ADMIN_TOKEN}
      - CONVERT_COLOR=\${CONVERT_COLOR}
      - SOURCE_ORDER=\${SOURCE_ORDER}
      - OTHER_SERVER=\${OTHER_SERVER}
      - VOD_SERVERS=\${VOD_SERVERS}
      - VOD_RETURN_MODE=\${VOD_RETURN_MODE}
      - VOD_REQUEST_TIMEOUT=\${VOD_REQUEST_TIMEOUT}
      - YOUKU_CONCURRENCY=\${YOUKU_CONCURRENCY}
      - BILIBILI_COOKIE=\${BILIBILI_COOKIE}
    volumes:
      - "${DANMU_ENV_DIR}:/app/config"
EOF
  success "已生成 docker-compose.danmu-api.yml 示例"

  ######## 拉镜像 + 启动容器 ########

  info "拉取镜像 ${IMAGE_NAME}..."
  docker pull "${IMAGE_NAME}" || warn "拉取失败，将尝试使用本地已有镜像（如果存在）"

  info "启动 danmu-api 容器..."
  docker run -d \
    --name danmu-api \
    --restart unless-stopped \
    -p "${PORT}:9321" \
    -v "${DANMU_ENV_DIR}:/app/config" \
    -e "TOKEN=${TOKEN}" \
    -e "ADMIN_TOKEN=${ADMIN_TOKEN}" \
    -e "CONVERT_COLOR=${CONVERT_COLOR}" \
    -e "SOURCE_ORDER=${SOURCE_ORDER}" \
    -e "OTHER_SERVER=${OTHER_SERVER}" \
    -e "VOD_SERVERS=${VOD_SERVERS}" \
    -e "VOD_RETURN_MODE=${VOD_RETURN_MODE}" \
    -e "VOD_REQUEST_TIMEOUT=${VOD_REQUEST_TIMEOUT}" \
    -e "YOUKU_CONCURRENCY=${YOUKU_CONCURRENCY}" \
    -e "BILIBILI_COOKIE=${BILIBILI_COOKIE}" \
    "${IMAGE_NAME}" >/dev/null

  success "danmu-api 容器已启动"

  # 自动更新：每天凌晨 4 点（Asia/Shanghai）
  if [ "$AUTO_UPDATE" = "1" ]; then
    info "启动 Watchtower 自动更新..."
    docker run -d \
      --name watchtower-danmu-api \
      -v /var/run/docker.sock:/var/run/docker.sock \
      --restart always \
      -e DOCKER_API_VERSION=1.44 \
      -e TZ=Asia/Shanghai \
      -e WATCHTOWER_SCHEDULE="0 0 4 * * *" \
      containrrr/watchtower \
      danmu-api >/dev/null
    success "Watchtower 已启动（每天凌晨 4 点自动检查 danmu-api 更新）"
  fi

  ######## 生成 README 提示 ########

  local ipv4
  ipv4="$(detect_ipv4)"

  cat > README_danmu-api.txt <<EOF
LogVar 弹幕 API 部署成功说明
==============================

普通访问（TOKEN）：
  http://${ipv4:-你的服务器IP}:${PORT}/${TOKEN}

管理访问（ADMIN_TOKEN）：
  http://${ipv4:-你的服务器IP}:${PORT}/${ADMIN_TOKEN}

查看容器：
  docker ps

查看日志：
  docker logs -f danmu-api

重启服务：
  docker restart danmu-api

停止服务：
  docker stop danmu-api

卸载：
  bash $(basename "$0") uninstall

运行时 .env：
  ${DANMU_ENV_FILE}
EOF

  success "已生成 README_danmu-api.txt"

  echo
  echo "================== 部署完成 =================="
  echo "普通访问： http://${ipv4:-你的服务器IP}:${PORT}/${TOKEN}"
  echo "管理访问： http://${ipv4:-你的服务器IP}:${PORT}/${ADMIN_TOKEN}"
  echo "查看日志： docker logs -f danmu-api"
  [ "$AUTO_UPDATE" = "1" ] && echo "自动更新： 已启用（watchtower-danmu-api，每天 4 点）" || echo "自动更新： 已关闭"
  echo "=============================================="
}

#################### 主入口 ####################

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
