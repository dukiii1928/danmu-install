#!/usr/bin/env bash
# 一键部署 LogVar 弹幕 API (Docker 版)
# 适用于：Debian / Ubuntu / 其他使用 apt 的发行版
set -e

#######################################
# 工具函数
#######################################
print_line() {
  printf '\n============================================================\n'
}

ask_with_default() {
  local prompt="$1"
  local default="$2"
  local var
  read -rp "${prompt} [默认: ${default}] " var
  if [[ -z "${var}" ]]; then
    echo "${default}"
  else
    echo "${var}"
  fi
}

ask_yes_no() {
  local prompt="$1"
  local default="$2"   # y 或 n
  local var
  local default_text

  if [[ "${default}" == "y" ]]; then
    default_text="Y/n"
  else
    default_text="y/N"
  fi

  while true; do
    read -rp "${prompt} [${default_text}] " var
    var="${var,,}"   # 转小写

    if [[ -z "${var}" ]]; then
      var="${default}"
    fi

    case "${var}" in
      y|yes) echo "y"; return 0 ;;
      n|no)  echo "n"; return 0 ;;
      *) echo "请输入 y 或 n." ;;
    esac
  done
}

detect_pkg_mgr() {
  if command -v apt-get >/dev/null 2>&1; then
    echo "apt"
  elif command -v yum >/dev/null 2>&1; then
    echo "yum"
  elif command -v dnf >/dev/null 2>&1; then
    echo "dnf"
  else
    echo "unknown"
  fi
}

ensure_cmd() {
  local cmd="$1"
  local pkg="$2"

  if command -v "${cmd}" >/dev/null 2>&1; then
    return 0
  fi

  local mgr
  mgr="$(detect_pkg_mgr)"
  echo "未检测到 ${cmd}，正在安装 ${pkg}..."

  case "${mgr}" in
    apt)
      apt-get update -y
      apt-get install -y "${pkg}"
      ;;
    yum)
      yum install -y "${pkg}"
      ;;
    dnf)
      dnf install -y "${pkg}"
      ;;
    *)
      echo "无法自动安装 ${pkg}，请手动安装后重试。"
      exit 1
      ;;
  esac
}

detect_ip() {
  # 优先获取公网 IP，失败再回退到内网 IP
  local ip
  ip="$(curl -fsSL ipv4.icanhazip.com 2>/dev/null || curl -fsSL ifconfig.me 2>/dev/null || true)"
  if [[ -n "${ip}" ]]; then
    echo "${ip}"
  else
    ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
    echo "${ip:-你的服务器IP}"
  fi
}

#######################################
# 0. 检查 root 权限
#######################################
if [[ "$(id -u)" -ne 0 ]]; then
  echo "请使用 root 运行此脚本（sudo su 或 sudo bash install.sh）"
  exit 1
fi

clear
print_line
echo "         LogVar 弹幕 API · Docker 超级一键部署脚本"
print_line
echo

#######################################
# 1. 收集配置
#######################################

# 端口
PORT="$(ask_with_default "请输入服务端口" "8080")"

# TOKEN 与 ADMIN_TOKEN
TOKEN="$(ask_with_default "请输入普通访问 TOKEN" "123987456")"
ADMIN_TOKEN="$(ask_with_default "请输入管理访问 ADMIN_TOKEN" "admin_888999")"

# 颜色模式
echo
echo "请选择弹幕颜色转换模式（CONVERT_COLOR）："
echo "  1) default - 不转换弹幕颜色"
echo "  2) white   - 将所有非白色弹幕转换为纯白色"
echo "  3) color   - 将所有白色弹幕转换为随机颜色（包含白色，白色概率更高）"
COLOR_CHOICE="$(ask_with_default "请输入选项序号" "3")"

case "${COLOR_CHOICE}" in
  1) CONVERT_COLOR="default" ;;
  2) CONVERT_COLOR="white" ;;
  3) CONVERT_COLOR="color" ;;
  *) echo "输入无效，使用默认 color"; CONVERT_COLOR="color" ;;
esac

# 是否启用自动更新（watchtower）
AUTO_UPDATE="$(ask_yes_no "是否启用每日 04:00 自动拉取最新镜像并重启容器？" "y")"

#######################################
# 2. 安装依赖：curl & docker
#######################################
echo
print_line
echo "正在安装依赖：curl / docker..."
print_line

ensure_cmd curl curl
if ! command -v docker >/dev/null 2>&1; then
  echo "未检测到 docker，正在安装..."
  mgr="$(detect_pkg_mgr)"
  case "${mgr}" in
    apt)
      apt-get update -y
      apt-get install -y docker.io
      ;;
    yum)
      yum install -y docker
      ;;
    dnf)
      dnf install -y docker
      ;;
    *)
      echo "无法自动安装 docker，请手动安装后重试。"
      exit 1
      ;;
  esac
fi

# 启动并设置 docker 开机自启
if command -v systemctl >/dev/null 2>&1; then
  systemctl enable --now docker
else
  service docker start || true
fi

#######################################
# 3. 部署 danmu-api 容器
#######################################
echo
print_line
echo "开始部署 danmu-api 容器..."
print_line

# 先删除旧容器（若存在）
docker rm -f danmu-api >/dev/null 2>&1 || true
docker rm -f danmu-watchtower >/dev/null 2>&1 || true

# 拉取镜像（可选：直接 run 会自动拉取，这里仅提示一下）
echo "拉取镜像 logvar/danmu-api:latest ..."
docker pull logvar/danmu-api:latest

# 启动弹幕 API 容器
docker run -d \
  --name danmu-api \
  -p "${PORT}:9321" \
  -e TOKEN="${TOKEN}" \
  -e ADMIN_TOKEN="${ADMIN_TOKEN}" \
  -e CONVERT_COLOR="${CONVERT_COLOR}" \
  --restart unless-stopped \
  logvar/danmu-api:latest

#######################################
# 4. 部署自动更新（可选）
#######################################
if [[ "${AUTO_UPDATE}" == "y" ]]; then
  echo
  print_line
  echo "启用 Watchtower 自动更新（每天 04:00 检查 danmu-api 镜像并更新）..."
  print_line

  docker run -d \
    --name danmu-watchtower \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -e TZ=Asia/Shanghai \
    -e WATCHTOWER_SCHEDULE="0 0 4 * * *" \
    --restart always \
    containrrr/watchtower danmu-api
fi

#######################################
# 5. 输出访问信息 & 管理指令
#######################################
IP_ADDR="$(detect_ip)"

echo
print_line
echo "  部署完成！弹幕 API 服务已经启动"
print_line
echo
echo "  普通访问（TOKEN）地址："
echo "    http://${IP_ADDR}:${PORT}/${TOKEN}"
echo
echo "  管理访问（ADMIN_TOKEN）地址："
echo "    http://${IP_ADDR}:${PORT}/${ADMIN_TOKEN}"
echo
echo "  当前配置："
echo "    端口(PORT)         : ${PORT}"
echo "    TOKEN              : ${TOKEN}"
echo "    ADMIN_TOKEN        : ${ADMIN_TOKEN}"
echo "    CONVERT_COLOR      : ${CONVERT_COLOR}"
if [[ "${AUTO_UPDATE}" == "y" ]]; then
  echo "    自动更新           : 已启用（每日 04:00 通过 Watchtower 更新容器）"
else
  echo "    自动更新           : 未启用"
fi

echo
echo "  常用管理命令："
echo "    查看运行中的容器： docker ps"
echo "    查看实时日志：     docker logs -f danmu-api"
echo "    重启服务：         docker restart danmu-api"
echo "    停止服务：         docker stop danmu-api"
echo "    删除服务：         docker rm -f danmu-api"
if [[ "${AUTO_UPDATE}" == "y" ]]; then
  echo "    查看更新日志：     docker logs -f danmu-watchtower"
fi

print_line
echo "如果服务器前有防火墙 / 安全组，请放行 TCP 端口：${PORT}"
echo "如果你之后绑定域名，只需将域名解析到该服务器 IP 即可使用。"
print_line
echo
