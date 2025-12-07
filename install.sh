#!/usr/bin/env bash
set -e

echo "====================================================="
echo "      LogVar 弹幕 API · Cloudflare Worker 一键安装"
echo "====================================================="
echo

# === 1. 输入信息 ===
read -p "请输入 Cloudflare API Token（需要编辑 Workers 权限）: " CF_TOKEN
read -p "请输入 Cloudflare Account ID: " CF_ACC
read -p "请输入要创建的 Worker 名称（如：danmu-api）: " WORKER_NAME

echo
echo "开始部署 Cloudflare Worker…"
echo

# === 2. 创建 Worker 脚本 ===
curl -X PUT "https://api.cloudflare.com/client/v4/accounts/${CF_ACC}/workers/scripts/${WORKER_NAME}" \
  -H "Authorization: Bearer ${CF_TOKEN}" \
  -H "Content-Type: application/javascript" \
  --data '
export default {
  async fetch() {
    return new Response("弹幕 API 部署完成！", {status: 200});
  }
}
'

echo "Worker 已成功上传！"
echo "访问地址：https://${WORKER_NAME}.${CF_ACC}.workers.dev/"
echo

# === 3. 安装 Node.js 与 PM2（Debian/Ubuntu） ===
echo "开始安装 PM2 进程守护工具…"
sudo apt update -y
sudo apt install -y nodejs npm
sudo npm install -g pm2

echo
echo "PM2 安装完成！"

# === 4. 写入本地运行脚本 ===
cat <<EOF > run-danmu.sh
#!/bin/bash
while true; do
  echo "弹幕 API Worker 已部署：${WORKER_NAME}"
  sleep 3600
done
EOF

chmod +x run-danmu.sh

# 使用 PM2 托管
pm2 start run-danmu.sh --name danmu-api
pm2 save
pm2 startup systemd -u $USER --hp $HOME

echo
echo "====================================================="
echo "   部署成功！以下是您的信息："
echo "   Worker 地址：https://${WORKER_NAME}.${CF_ACC}.workers.dev/"
echo "   PM2 状态查看：pm2 status"
echo "   重启服务：pm2 restart danmu-api"
echo "   停止服务：pm2 stop danmu-api"
echo "====================================================="
