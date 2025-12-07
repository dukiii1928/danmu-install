#!/usr/bin/env bash
# LogVar 弹幕 API / danmu-api 超级一键部署脚本
# 说明：
# - 自动安装 curl / Docker（若未安装）
# - 拉取 logvar/danmu-api:latest 镜像
# - 交互设置 TOKEN / ADMIN_TOKEN / 颜色模式 / 映射端口
# - 使用 Watchtower 每天凌晨 4 点自动更新 danmu-api 容器
# - 最后输出访问地址：普通访问 & 管理访问

set -euo pipefail

### 工具函数
command_exists() {
  command -v "$1" >/dev/null 2>&1
}

print_line() {
  echo "============================================================"
}

### 0. 权限检查
if [[ "$EUID" -ne 0 ]]; then
  echo "❌ 请使用 root 账户运行本脚本（例如：sudo -i 后执行）。"
  exit 1
fi

clear
print_line
echo "          LogVar 弹幕 API / danmu-api 一键部署"
print_line
echo

### 1. 安装 curl（如缺失）
if ! command_exists curl; then
  echo "▶ 检测到未安装 curl，正在安装..."
  if command_exists apt; then
    apt update -y && apt install -y curl
  elif command_exists yum; then
    yum install -y curl
  elif command_exists dnf; then
    dnf install -y curl
  else
    echo "❌ 未找到可用的包管理器（apt / yum / dnf），请手动安装 curl 后重试。"
    exit 1
  fi
else
  echo "✔ curl 已安装"
fi
echo

### 2. 安装 Docker（如缺失）
if ! command_exists docker; then
  echo "▶ 未检测到 Docker，正在通过官方脚本安装..."
  curl -fsSL https://get.docker.com | sh
  echo "✔ Docker 安装完成"
else
  echo "✔ Docker 已安装"
fi
echo

### 3. 交互式配置
echo "▶ 开始进行参数配置（直接回车使用默认值）"
echo

# 默认值
DEFAULT_PORT=8080
DEFAULT_TOKEN="123987456"
DEFAULT_ADMIN_TOKEN="admin_888999"
DEFAULT_COLOR="color"   # default / white / color
DEFAULT_AUTO_UPDATE="Y" # Y / n

# 端口
read -rp "映射到本机的访问端口 [默认: ${DEFAULT_PORT}] : " PORT
PORT=${PORT:-$DEFAULT_PORT}

# 普通 TOKEN
read -rp "普通访问 TOKEN [默认: ${DEFAULT_TOKEN}] : " TOKEN
TOKEN=${TOKEN:-$DEFAULT_TOKEN}

# 管理 TOKEN
read -rp "管理访问 ADMIN_TOKEN [默认: ${DEFAULT_ADMIN_TOKEN}] : " ADMIN_TOKEN
ADMIN_TOKEN=${ADMIN_TOKEN:-$DEFAULT_ADMIN_TOKEN}

# 颜色模式
echo
echo "弹幕颜色模式 CONVERT_COLOR 选项："
echo "  default : 不转换弹幕颜色"
echo "  white   : 将所有非白色弹幕转换为纯白色"
echo "  color   : 将所有白色弹幕转换为随机颜色（包含白色，白色概率更高）"
read -rp "请选择颜色模式 CONVERT_COLOR [默认: ${DEFAULT_COLOR}] : " COLOR_MODE
COLOR_MODE=${COLOR_MODE:-$DEFAULT_COLOR}

# 自动更新
echo
read -rp "是否安装 Watchtower 自动更新（每天凌晨 4 点）? [Y/n] (默认: ${DEFAULT_AUTO_UPDATE}) : " AUTO_UPDATE
AUTO_UPDATE=${AUTO_UPDATE:-$DEFAULT_AUTO_UPDATE}

echo
print_line
echo "当前配置为："
echo "  访问端口         : ${PORT}"
echo "  TOKEN            : ${TOKEN}"
echo "  ADMIN_TOKEN      : ${ADMIN_TOKEN}"
echo "  颜色模式         : ${COLOR_MODE}"
echo "  自动更新（4:00） : ${AUTO_UPDATE}"
print_line
echo

read -rp "确认开始部署? [回车继续 / Ctrl+C 取消] " _

### 4. 拉取镜像并部署 danmu-api 容器
echo
echo "▶ 正在拉取 danmu-api 镜像..."
docker pull logvar/danmu-api:latest

echo "▶ 删除旧的 danmu-api 容器（如存在）..."
docker rm -f danmu-api >/dev/null 2>&1 || true

echo "▶ 创建并启动新的 danmu-api 容器..."
docker run -d \
  -p "${PORT}:9321" \
  --name danmu-api \
  -e TOKEN="${TOKEN}" \
  -e ADMIN_TOKEN="${ADMIN_TOKEN}" \
  -e CONVERT_COLOR="${COLOR_MODE}" \
  --restart unless-stopped \
  logvar/danmu-api:latest

echo "✔ danmu-api 容器已启动"
echo

### 5. 配置 Watchtower 自动更新（可选）
if [[ "${AUTO_UPDATE}" == "Y" || "${AUTO_UPDATE}" == "y" ]]; then
  echo "▶ 配置 Watchtower 每天凌晨 4 点自动更新 danmu-api 容器..."

  # 删除旧 watchtower
  docker rm -f watchtower >/dev/null 2>&1 || true

  docker run -d \
    --name watchtower \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -e DOCKER_API_VERSION=1.44 \
    -e TZ=Asia/Shanghai \
    -e WATCHTOWER_SCHEDULE="0 0 4 * * *" \
    --restart always \
    containrrr/watchtower \
    danmu-api

  echo "✔ Watchtower 已启动，将在每天 04:00 自动检查并更新 danmu-api 镜像"
else
  echo "⚠ 已选择不安装 Watchtower 自动更新"
fi
echo

### 6. 显示访问信息
# 尝试获取本机 IP（优先内网 IP）
LOCAL_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
if [[ -z "${LOCAL_IP}" ]]; then
  LOCAL_IP="你的服务器IP"
fi

print_line
echo "  🎉 部署完成！弹幕 API 服务已经启动"
print_line
echo
echo "  普通访问（TOKEN）地址："
echo "    http://${LOCAL_IP}:${PORT}/${TOKEN}"
echo
echo "  管理访问（ADMIN_TOKEN）地址："
echo "    http://${LOCAL_IP}:${PORT}/${ADMIN_TOKEN}"
echo
echo "  当前配置："
echo "    端口          : ${PORT}"
echo "    TOKEN         : ${TOKEN}"
echo "    ADMIN_TOKEN   : ${ADMIN_TOKEN}"
echo "    CONVERT_COLOR : ${COLOR_MODE}"
if [[ "${AUTO_UPDATE}" == "Y" || "${AUTO_UPDATE}" == "y" ]]; then
  echo "    自动更新      : 已启用（每天 04:00 通过 Watchtower 更新容器）"
else
  echo "    自动更新      : 未启用"
fi
echo
echo "  管理命令示例："
echo "    查看容器： docker ps"
echo "    查看日志： docker logs -f danmu-api"
echo "    重启服务： docker restart danmu-api"
echo "    更新镜像： docker pull logvar/danmu-api:latest && docker restart danmu-api"
echo
print_line
echo "  如果服务器有公网 IP，外网用户也可以用上面的地址访问。"
echo "  若绑定域名，只需将域名解析到此服务器 IP 即可使用。"
print_line
echo
