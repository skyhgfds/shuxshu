#!/usr/bin/env bash

# 定义颜色，使输出更易读
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
RESET="\033[0m"

# 脚本必须以 root 权限运行
[[ $EUID -ne 0 ]] && echo -e "${RED}错误: 请以 root 权限运行此脚本 (使用 sudo -i)${RESET}" && exit 1

# 函数：下载 cloudflared，包含重试和回退机制
download_cloudflared() {
    echo -e "${YELLOW}>>> 正在准备 Cloudflare Tunnel...${RESET}"
    local download_url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64"
    local install_path="/usr/local/bin/cloudflared"
    
    # 1. 如果 cloudflared 已安装且可执行，则跳过下载
    if [ -x "$install_path" ]; then
        echo -e "${GREEN}Cloudflared 已存在，跳过下载。${RESET}"
        return 0
    fi

    # 2. 尝试使用 curl 或 wget 下载，最多重试3次
    for i in {1..3}; do
        echo -e "${YELLOW}尝试下载 Cloudflared (第 $i 次)...${RESET}"
        if command -v curl &>/dev/null; then
            # 使用 curl 下载
            curl -fsSL "$download_url" -o "$install_path"
        elif command -v wget &>/dev/null; then
            # 如果没有 curl，使用 wget
            wget -qO "$install_path" "$download_url"
        else
            echo -e "${RED}错误: 系统中未找到 'curl' 或 'wget'，无法继续。${RESET}"
            return 1
        fi

        # 检查下载是否成功
        if [ $? -eq 0 ]; then
            chmod +x "$install_path"
            echo -e "${GREEN}Cloudflared 下载成功。${RESET}"
            return 0
        fi
        echo -e "${YELLOW}下载失败，2秒后重试...${RESET}"
        sleep 2
    done

    echo -e "${RED}错误: 下载 Cloudflared 失败。请检查您的网络连接或防火墙设置。${RESET}"
    return 1
}

# 函数：配置 SSH 服务
configure_ssh() {
    echo -e "${YELLOW}>>> 正在配置 SSH 服务...${RESET}"
    
    # 1. 强制修改 sshd_config 以允许 root 登录和密码认证
    sed -i -e 's/^#?PermitRootLogin.*/PermitRootLogin yes/g' \
           -e 's/^#?PasswordAuthentication.*/PasswordAuthentication yes/g' /etc/ssh/sshd_config

    # 2. 设置 root 密码
    echo "root:$PASSWORD" | chpasswd
    echo -e "${GREEN}SSH root 登录和密码已配置。${RESET}"

    # 3. 重启 SSH 服务以应用更改
    if systemctl restart sshd; then
        echo -e "${GREEN}SSH 服务已重启。${RESET}"
    else
        echo -e "${RED}SSH 服务重启失败，请手动检查。${RESET}"
    fi
}

# 函数：启动 Cloudflare Tunnel
start_tunnel() {
    echo -e "${YELLOW}>>> 正在启动 Cloudflare Tunnel...${RESET}"
    
    # 您的隧道 Token
    local tunnel_token="eyJhIjoiZTY1Mjg3ZmQ5NzMyZmE5Yjc0NjVkMWZhZTdmMmZlYTIiLCJ0IjoiZmIxNGNlM2MtNmI1Zi00MDBhLWE1ODEtYmJhMDYwNTU4ODA1IiwicyI6Ik9HRmpObVZsTTJFdFl6Y3laUzAwWldOakxUbGxNall0TTJFMU1UWTNOV0psTnpnMSJ9"

    # 清理任何可能存在的旧进程
    pkill -f "cloudflared tunnel run" >/dev/null 2>&1
    sleep 1

    # 在后台运行 cloudflared
    nohup /usr/local/bin/cloudflared tunnel --no-autoupdate run --token "${tunnel_token}" > /tmp/cloudflared.log 2>&1 &
    sleep 5 # 等待隧道启动

    # 检查进程是否存在
    if ! pgrep -f "cloudflared tunnel run" > /dev/null; then
        echo -e "${RED}错误: Cloudflare Tunnel 未能启动！${RESET}"
        echo -e "${YELLOW}请通过 'cat /tmp/cloudflared.log' 查看日志获取详细信息。${RESET}"
        return 1
    fi
    
    echo -e "${GREEN}Cloudflare Tunnel 已成功在后台启动。${RESET}"
    return 0
}

# --- 主程序 ---
main() {
    echo -e "${GREEN}===== 开始设置 SSH 和 Cloudflare Tunnel =====${RESET}"

    # 1. 获取用户输入的密码
    while true; do
        read -p "请输入新的 root 密码 (至少10位): " PASSWORD
        if [[ -z "$PASSWORD" ]]; then
            echo -e "${RED}错误: 密码不能为空。${RESET}"
        elif [[ ${#PASSWORD} -lt 10 ]]; then
            echo -e "${RED}错误: 密码长度至少需要10位。${RESET}"
        else
            break
        fi
    done

    # 2. 下载 cloudflared
    download_cloudflared || exit 1
    
    # 3. 配置 SSH
    configure_ssh
    
    # 4. 启动隧道
    start_tunnel || exit 1

    # 5. 显示最终结果
    echo -e "\n${GREEN}===== ✅ 设置成功 =====${RESET}"
    echo -e "您现在可以通过在 Cloudflare 仪表板中配置的【公共主机名】连接到此环境。"
    echo -e "隧道已连接到本机的 ${GREEN}localhost:22${RESET}。\n"
    echo -e "--- 连接信息 ---"
    echo -e "${GREEN}SSH 用户名: ${RESET}root"
    echo -e "${GREEN}SSH 密  码: ${RESET}${PASSWORD}"
    echo -e "${GREEN}SSH 地  址: ${RESET}<您在 Cloudflare 配置的域名>"
    echo -e "${GREEN}SSH 端  口: ${RESET}<您在 Cloudflare 配置的端口>"
    echo -e "------------------\n"
    echo -e "${YELLOW}注意: cloudflared 进程在后台运行，如需停止请使用 'pkill -f cloudflared' 命令。${RESET}"
}

# 执行主函数
main
