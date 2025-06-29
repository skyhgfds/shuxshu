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
  echo -e "${YELLOW}[3/4] 正在解除 SSH 和 Docker 服务的锁定...${RESET}"
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
  echo -e "${YELLOW}[2/4] 正在配置 SSH 服务，允许 root 登录和密码认证...${RESET}"
  # 确保 sshd 服务已启动
  systemctl start sshd 2>/dev/null || true
  
  lsof -i:22 | awk '/IPv4/{print $2}' | xargs kill -9 2>/dev/null || true

  # 强制修改 sshd_config
  sed -i 's/^#?PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
  sed -i 's/^#?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
  
  echo root:$PASSWORD | chpasswd

  # 重启 SSH 服务以应用配置
  systemctl restart sshd
}

# 设置 SSH 和隧道的脚本
echo -e "${GREEN}===== 开始设置 SSH 和 Cloudflare Tunnel =====${RESET}"

echo -e "${YELLOW}[1/4] 获取必要信息...${RESET}"
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

echo -e "${YELLOW}[4/4] 正在下载和配置 Cloudflare Tunnel...${RESET}"
# 下载 cloudflared
wget https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 -qO /usr/local/bin/cloudflared
if [ $? -ne 0 ]; then
    echo -e "${RED}错误: 下载 cloudflared 失败，请检查网络连接。${RESET}"
    exit 1
fi
chmod +x /usr/local/bin/cloudflared

# 清理可能存在的旧进程
pkill -f cloudflared >/dev/null 2>&1 || true
sleep 1

# 您的隧道 Token
TUNNEL_TOKEN="eyJhIjoiZTY1Mjg3ZmQ5NzMyZmE5Yjc0NjVkMWZhZTdmMmZlYTIiLCJ0IjoiZmIxNGNlM2MtNmI1Zi00MDBhLWE1ODEtYmJhMDYwNTU4ODA1IiwicyI6Ik9HRmpObVZsTTJFdFl6Y3laUzAwWldOakxUbGxNall0TTJFMU1UWTNOV0psTnpnMSJ9"

# 以后台模式运行 cloudflared
nohup /usr/local/bin/cloudflared tunnel --no-autoupdate run --token ${TUNNEL_TOKEN} > /tmp/cloudflared.log 2>&1 &

echo -e "${YELLOW}等待 Cloudflare Tunnel 服务启动...${RESET}"
sleep 5

# 检查服务是否在运行
if ! pgrep -f "cloudflared tunnel run" > /dev/null; then
    echo -e "${RED}错误: Cloudflare Tunnel 未能启动。${RESET}"
    echo -e "${YELLOW}请检查日志 /tmp/cloudflared.log 获取详细错误。${RESET}"
    exit 1
fi

echo -e "${GREEN}===== 设置完成 =====${RESET}"
echo ""
echo -e "${GREEN}Cloudflare Tunnel 已使用您的 Token 在后台成功启动。${RESET}"
echo ""
echo -e "${YELLOW}您现在需要通过在 Cloudflare Zero Trust 仪表板中配置的公共主机名进行连接。${RESET}"
echo -e "该隧道连接到本机的 ${GREEN}localhost:22${RESET}。请确保您已在 Cloudflare 上设置了指向该服务的公共主机名。"
echo ""
echo -e "连接信息:"
echo -e "${GREEN}SSH 地址: ${RESET}<您在 Cloudflare 上配置的地址 (例如: ssh.yourdomain.com)>"
echo -e "${GREEN}SSH 端口: ${RESET}<您在 Cloudflare 上配置的端口>"
echo -e "${GREEN}SSH 用户: ${RESET}root"
echo -e "${GREEN}SSH 密码: ${RESET}$PASSWORD"
echo ""
echo -e "${YELLOW}注意: cloudflared 进程在后台运行，如需停止请使用 'pkill -f cloudflared' 命令${RESET}"
echo ""
