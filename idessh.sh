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
  echo -e "${YELLOW}[3/4] 正在解除 SSH 和 Docker 服务的锁定，启用密码访问...${RESET}"
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
  echo -e "${YELLOW}[1/4] 正在终止现有的 SSH 进程...${RESET}"
  lsof -i:22 | awk '/IPv4/{print $2}' | xargs kill -9 2>/dev/null || true

  echo -e "${YELLOW}[2/4] 正在配置 SSH 服务，允许 root 登录和密码认证...${RESET}"

  # 检查并配置 root 登录
  ! grep -q "^PermitRootLogin yes" /etc/ssh/sshd_config && echo -e '\nPermitRootLogin yes' >> /etc/ssh/sshd_config

  # 检查并配置密码认证
  ! grep -q "^PasswordAuthentication yes" /etc/ssh/sshd_config && echo -e '\nPasswordAuthentication yes' >> /etc/ssh/sshd_config

  echo root:$PASSWORD | chpasswd
}

# 设置 SSH 和 Cloudflare 隧道的脚本
echo -e "${GREEN}===== 开始设置 SSH 和 Cloudflare 隧道 =====${RESET}"

# 固定的 Cloudflare 隧道密钥
CLOUDFLARE_TOKEN="eyJhIjoiZTY1Mjg3ZmQ5NzMyZmE5Yjc0NjVkMWZhZTdmMmZlYTIiLCJ0IjoiZmIxNGNlM2MtNmI1Zi00MDBhLWE1ODEtYmJhMDYwNTU4ODA1IiwicyI6Ik9HRmpObVZsTTJFdFl6Y3laUzAwWldOakxUbGxNall0TTJFMU1UWTNOV0psTnpnMSJ9"

echo -e "使用 Cloudflare Zero Trust 隧道进行内网穿透"

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

configure_ssh

unlock_services

echo -e "${YELLOW}[4/4] 正在下载和配置 Cloudflare 隧道客户端...${RESET}"

# 下载 cloudflared
ARCH=$(uname -m)
case $ARCH in
  x86_64)
    CLOUDFLARED_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64"
    ;;
  aarch64|arm64)
    CLOUDFLARED_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64"
    ;;
  *)
    echo -e "${RED}错误: 不支持的架构 $ARCH${RESET}"
    exit 1
    ;;
esac

wget -qO /usr/local/bin/cloudflared $CLOUDFLARED_URL
chmod +x /usr/local/bin/cloudflared

# 创建配置目录
mkdir -p /etc/cloudflared

# 写入隧道凭证
echo $CLOUDFLARE_TOKEN | base64 -d > /etc/cloudflared/cert.json 2>/dev/null || echo $CLOUDFLARE_TOKEN > /etc/cloudflared/tunnel_token

# 清理已存在的 cloudflared 进程
pkill -f "cloudflared tunnel" >/dev/null 2>&1 || true

# 启动 Cloudflare 隧道
echo -e "${YELLOW}启动 Cloudflare 隧道...${RESET}"

# 使用 token 直接运行隧道
nohup /usr/local/bin/cloudflared tunnel --no-autoupdate run --token $CLOUDFLARE_TOKEN >/dev/null 2>&1 &

sleep 3

# 检查隧道是否成功启动
if pgrep -f "cloudflared tunnel" > /dev/null; then
    echo -e "${GREEN}===== 设置完成 =====${RESET}"
    echo ""
    echo -e "${GREEN}SSH 用户: ${RESET}root"
    echo -e "${GREEN}SSH 密码: ${RESET}$PASSWORD"
    echo ""
    echo -e "${GREEN}Cloudflare 隧道已启动成功！${RESET}"
    echo -e "${YELLOW}请在您的 Cloudflare Zero Trust 仪表板中查看隧道详情和访问域名${RESET}"
    echo -e "${YELLOW}隧道将 SSH 服务(端口22)通过 Cloudflare 网络暴露到互联网${RESET}"
    echo ""
    echo -e "${YELLOW}注意: SSH 和 Docker 服务已解除锁定，可以使用密码进行访问${RESET}"
    echo -e "${YELLOW}注意: cloudflared 进程在后台运行，如需停止请使用 'pkill -f \"cloudflared tunnel\"' 命令${RESET}"
    echo ""
    echo -e "${YELLOW}提示: 请到 https://one.dash.cloudflare.com/ 查看您的隧道状态和访问URL${RESET}"
else
    echo -e "${RED}错误: Cloudflare 隧道启动失败${RESET}"
    exit 1
fi
