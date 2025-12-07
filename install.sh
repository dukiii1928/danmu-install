#!/usr/bin/env bash
set -e

echo "====================================================="
echo "        LogVar 弹幕 API · Docker 一键安装脚本"
echo "             仅部署 danmu-api 容器"
echo "====================================================="
echo

# ===== 0. 确保有 curl =====
if ! command -v curl >/dev/null 2>&1; then
  echo "未检测到 curl，正在尝试自动安装 curl..."
  if command -v apt >/dev/null 2>&1; then
    apt update && apt install -y curl
  elif command -v yum >/dev/null 2>&1; then
    yum install -y curl
  else
    echo "未检测到 apt / yum，无法自动安装 curl，请手动安装后重试。"
    exit 1
  fi
fi

# ===== 1. 确保安装 Docker =====
if ! command -v docker >/dev/null 2>&1; then
  echo "未检测到 Docker，正在通过官方脚本安装..."
  curl -fsSL https://get.docker.com | bash
  echo "Docker 安装完成。"
fi

# 保证 Docker 服务已启动
if command -v systemctl >/devnull 2>&1; then
  systemctl enable docker >/dev/null 2>&1 || true
  systemctl start docker  >/dev/null 2>&1 || true
fi

echo
echo "===== 基本配置 ====="

# ===== 2. 输入两个 TOKEN =====
read -p "请输入普通访问 TOKEN（用于前端访问，例如 123987456）: " USER_TOKEN
if [ -z "$USER_TOKEN" ]; then
  echo "普通访问 TOKEN 不能为空，退出。"
  exit 1
fi

read -p "请输入管理访问 ADMIN_TOKEN（用于后台管理，例如 admin_888999）: " ADMIN_TOKEN
if [ -z "$ADMIN_TOKEN" ]; then
  echo "ADMIN_TOKEN 不能为空，退出。"
  exit 1
fi

# ===== 3. 选择弹幕颜色模式 =====
echo
echo "请选择弹幕颜色转换模式（CONVERT_COLOR）："
echo "  1) default - 不转换弹幕颜色（推荐默认）"
echo "  2) white   - 将所有非白色的弹幕颜色转换为纯白色"
echo "  3) color   - 将所有白色弹幕转换为随机颜色（包含白色，增加白色出现概率）"
read -p "请输入数字 [1-3]，默认 1: " COLOR_CHOICE

case "$COLOR_CHOICE" in
  2)
    CONVERT_COLOR="white"
    ;;
  3)
    CONVERT_COLOR="color"
    ;;
  *)
    CONVERT_COLOR="default"
    ;;
esac

echo "已选择 CONVERT_COLOR = ${CONVERT_COLOR}"
echo

# ===== 4. 是否需要每天凌晨 4 点自动更新镜像（watchtower） =====
read -p "是否需要每天凌晨 4 点自动更新 danmu-api 镜像？(y/N): " AUTO_UPDATE
AUTO_UPDATE=${AUTO_UPDATE:-N}

# ===== 5. 映射端口（可自定义，默认 8080） =====
read -p "请输入本机映射端口（默认 8080，对外访问 http://IP:端口 ）: " HOST_PORT
HOST_PORT=${HOST_PORT:-8080}

echo
echo "===== 开始部署 danmu-api 容器 ====="

# 如果之前有同名容器，先停掉并删除
if docker ps -a --format '{{.Names}}' | grep -wq "danmu-api"; then
  echo "检测到已存在的 danmu-api 容器，正在删除旧容器..."
  docker stop danmu-api >/dev/null 2>&1 || true
  docker rm   danmu-api >/dev/null 2>&1 || true
fi

# 运行 danmu-api 容器
docker run -d \
  --name danmu-api \
  -p "${HOST_PORT}:9321" \
  -e TOKEN="${USER_TOKEN}" \
  -e ADMIN_TOKEN="${ADMIN_TOKEN}" \
  -e CONVERT_COLOR="${CONVERT_COLOR}" \
  --restart unless-stopped \
  logvar/danmu-api:latest

echo "danmu-api 容器已启动。"
echo

# ===== 6. 可选：部署 watchtower 自动更新 =====
if [[ "$AUTO_UPDATE" =~ ^[Yy]$ ]]; then
  echo "启用每日凌晨 4 点自动更新（watchtower）..."

  if docker ps -a --format '{{.Names}}' | grep -wq "danmu-watchtower"; then
    docker stop danmu-watchtower >/dev/null 2>&1 || true
    docker rm   danmu-watchtower >/dev/null 2>&1 || true
  fi

  docker run -d \
    --name danmu-watchtower \
    -v /var/run/docker.sock:/var/run/docker.sock \
    --restart always \
    -e DOCKER_API_VERSION=1.44 \
    -e TZ=Asia/Shanghai \
    -e WATCHTOWER_SCHEDULE="0 0 4 * * *" \
    containrrr/watchtower danmu-api

  echo "watchtower 已部署，将在每天凌晨 4 点检查并自动更新 danmu-api。"
else
  echo "已选择不启用自动更新，跳过 watchtower 部署。"
fi

echo

# ===== 7. 获取服务器 IP，并给出访问说明（只用 IP，不写域名） =====
SERVER_IP="$(curl -s ipv4.icanhazip.com || curl -s ifconfig.me || echo '你的服务器IP')"

echo "====================================================="
echo "                部署完成！重要信息如下"
echo "====================================================="
echo
echo "【danmu-api 后端容器】"
echo "  镜像： logvar/danmu-api:latest"
echo "  容器： danmu-api"
echo "  后端基础地址："
echo "    http://${SERVER_IP}:${HOST_PORT}"
echo
echo "【TOKEN 配置】"
echo "  普通访问 TOKEN = ${USER_TOKEN}"
echo "  管理访问 ADMIN_TOKEN = ${ADMIN_TOKEN}"
echo
echo "【前端实际访问地址】"
echo "  普通访问："
echo "    http://${SERVER_IP}:${HOST_PORT}/${USER_TOKEN}"
echo
echo "  管理访问："
echo "    http://${SERVER_IP}:${HOST_PORT}/${ADMIN_TOKEN}"
echo
echo "（上面两条就是你要公开给别人用的链接模板，"
echo "  他们如果自己绑了域名，就把 http://IP:端口 换成自己的域名即可。）"
echo
echo "【当前颜色模式 CONVERT_COLOR】"
echo "  ${CONVERT_COLOR}"
echo
echo "【容器管理命令】"
echo "  查看容器：   docker ps"
echo "  查看日志：   docker logs -f danmu-api"
echo "  重启容器：   docker restart danmu-api"
echo "  停止容器：   docker stop danmu-api"
echo
if [[ "$AUTO_UPDATE" =~ ^[Yy]$ ]]; then
  echo "【自动更新】"
  echo "  已启用 watchtower（容器名：danmu-watchtower）"
  echo "  每日 04:00 自动拉取最新镜像并更新 danmu-api"
else
  echo "【自动更新】"
  echo "  未启用自动更新，如需更新请手动执行："
  echo "    docker pull logvar/danmu-api:latest"
  echo "    docker restart danmu-api"
fi
echo
echo "====================================================="
echo "          普通访问（TOKEN = ${USER_TOKEN}）"
echo "          管理访问（ADMIN_TOKEN = ${ADMIN_TOKEN}）"
echo "====================================================="
