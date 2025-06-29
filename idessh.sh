#!/usr/bin/env bash

# 定义颜色
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
RESET="\033[0m"

# 检测是否具有 root 权限
[[ $EUID -ne 0 ]] && echo -e "${RED}错误: 请先运行 sudo -i 获取 root 权限后再执行此脚本${RESET}" && exit 1

# 解锁服务函数
unlock_services() {
  echo -e "${YELLOW}[4/5] 正在解除 SSH 和 Docker 服务的锁定，启用密码访问...${RESET}"
  if [ "$(systemctl is-active ssh)" != "active" ]; then
    systemctl unmask ssh 2>/dev/null || true
    systemctl start ssh 2>/dev/null || true
  fi

  if [[ "$(systemctl is-active docker)" != "active" || "$(systemctl is-active docker.socket)" != "active" ]]; then
    systemctl unmask containerd docker.socket docker 2>/dev/null || true
    pkill dockerd 2>/dev/null || true
    pkill containerd 2>/dev/null || true
    systemctl start containerd docker.socket docker 2>/dev/null || true
    sleep 2
  fi
}

# SSH 配置函数
configure_ssh() {
  echo -e "${YELLOW}[2/5] 正在终止现有的 SSH 进程...${RESET}"
  lsof -i:22 | awk '/IPv4/{print $2}' | xargs kill -9 2>/dev/null || true

  echo -e "${YELLOW}[3/5] 正在配置 SSH 服务，允许 root 登录和密码认证...${RESET}"

  # 检查并配置 root 登录
  ! grep -q "^PermitRootLogin yes" /etc/ssh/sshd_config && echo -e '\nPermitRootLogin yes' >> /etc/ssh/sshd_config

  # 检查并配置密码认证
  ! grep -q "^PasswordAuthentication yes" /etc/ssh/sshd_config && echo -e '\nPasswordAuthentication yes' >> /etc/ssh/sshd_config

  echo root:$PASSWORD | chpasswd
}

# 设置 SSH 和隧道的脚本
echo -e "${GREEN}===== 开始设置 SSH 和 Cloudflare Tunnel =====${RESET}"

echo -e "${YELLOW}[1/5] 获取必要信息...${RESET}"
# 获取密码，确保至少10位且不为空
while true; do
  read -p "请输入root密码 (至少10位): " PASSWORD
  if [[ -z "$PASSWORD" ]]; then
    echo -e "${RED}错误: 密码不能为空，请重新输入${RESET}"
  elif [[ ${#PASSWORD} -lt 10 ]]; then
    echo -e "${RED}错误: 密码长度不足10位，请重新输入${RESET}"
  else
    break
  fi
done

# 配置SSH
configure_ssh

# 解锁服务
unlock_services

echo -e "${YELLOW}[5/5] 正在下载和配置 Cloudflare Tunnel...${RESET}"
# 下载 cloudflared
wget https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 -O /usr/local/bin/cloudflared 2>/dev/null
if [ $? -ne 0 ]; then
    echo -e "${RED}错误: 下载 cloudflared 失败，请检查网络连接。${RESET}"
    exit 1
fi
chmod +x /usr/local/bin/cloudflared

# 清理可能存在的旧进程
pkill -f cloudflared >/dev/null 2>&1 || true
sleep 1

# 以后台模式运行 cloudflared 并将日志输出到临时文件
nohup cloudflared tunnel --url tcp://localhost:22 > /tmp/cloudflared.log 2>&1 &

echo -e "${YELLOW}等待 Cloudflare Tunnel 服务启动... (约15秒)${RESET}"
sleep 15

# 从日志中获取隧道信息
TUNNEL_URL=$(grep -o 'tcp://[a-zA-Z0-9-]*\.trycloudflare\.com:[0-9]*' /tmp/cloudflared.log | head -n 1)

if [ -z "$TUNNEL_URL" ]; then
  echo -e "${RED}错误: 无法获取 Cloudflare Tunnel 隧道信息。${RESET}"
  echo -e "${YELLOW}请检查日志 /tmp/cloudflared.log 获取详细错误。${RESET}"
  exit 1
fi

# 解析地址和端口
TUNNEL_INFO=$(echo $TUNNEL_URL | sed 's|tcp://||')
TUNNEL_HOST=$(echo $TUNNEL_INFO | cut -d: -f1)
TUNNEL_PORT=$(echo $TUNNEL_INFO | cut -d: -f2)

echo -e "${GREEN}===== 设置完成 =====${RESET}"
echo ""
echo -e "${GREEN}SSH 地址: ${RESET}$TUNNEL_HOST"
echo -e "${GREEN}SSH 端口: ${RESET}$TUNNEL_PORT"
echo -e "${GREEN}SSH 用户: ${RESET}root"
echo -e "${GREEN}SSH 密码: ${RESET}$PASSWORD"
echo ""
echo -e "${GREEN}使用以下命令连接到您的服务器:${RESET}"
echo -e "${GREEN}ssh root@$TUNNEL_HOST -p $TUNNEL_PORT${RESET}"
echo ""
echo -e "${YELLOW}注意: SSH 和 Docker 服务已解除锁定，可以使用密码进行访问${RESET}"
echo -e "${YELLOW}注意: cloudflared 进程在后台运行，如需停止请使用 'pkill -f cloudflared' 命令${RESET}"
echo ""
