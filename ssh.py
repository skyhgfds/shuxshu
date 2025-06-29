#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import os
import sys
import subprocess
import time
import signal
from pathlib import Path
import requests

# --- 用户配置 ---
# 1. 在这里填入你从 Cloudflare Zero Trust 仪表盘获取的 Tunnel Token
# 获取地址: Access -> Tunnels -> Create a tunnel
TUNNEL_TOKEN = "ey...YOUR_LONG_TOKEN...ifQ="

# 2. 为你的SSH连接设置一个密码
# 警告：请务必修改为一个强密码！
SSH_PASSWORD = "change_this_password" 

# 3. 你计划在 Cloudflare 上绑定的域名 (用于最终连接)
# 例如：ssh.yourdomain.com
SSH_DOMAIN = "ssh.yourdomain.com"
# --- 配置结束 ---

USER_HOME = Path.home()

class CloudflareTunnelManager:
    def __init__(self):
        self.cloudflared_path = USER_HOME / "cloudflared"
        self.tunnel_process = None

    def _run_command(self, command, check=True, capture_output=True):
        """辅助函数：运行shell命令并处理输出"""
        print(f"[*] 运行: {' '.join(command)}")
        try:
            # 对于需要交互或持续输出的命令，不捕获输出
            if not capture_output:
                 return subprocess.Popen(command)

            result = subprocess.run(command, capture_output=True, text=True, check=check, encoding='utf-8')
            if result.stdout:
                print(result.stdout.strip())
            if result.stderr:
                print(result.stderr.strip(), file=sys.stderr)
            return True
        except subprocess.CalledProcessError as e:
            print(f"✗ 命令执行失败 (返回码 {e.returncode}): {e}", file=sys.stderr)
            print(f"--- STDERR ---\n{e.stderr.strip()}", file=sys.stderr)
            return False
        except FileNotFoundError:
            print(f"✗ 命令未找到: {command[0]}. 请确保它已安装或在PATH中。", file=sys.stderr)
            return False
        except Exception as e:
            print(f"✗ 发生未知错误: {e}", file=sys.stderr)
            return False
            
    def setup_ssh_server(self):
        """安装并配置 Dropbear SSH 服务器"""
        print("\n--- 步骤 1: 设置 SSH 服务器 (Dropbear) ---")
        if os.geteuid() != 0:
            print("✗ 错误：需要root权限来安装软件和设置密码。请以root用户运行此脚本。", file=sys.stderr)
            return False

        print("[*] 更新软件包列表...")
        if not self._run_command(["apt-get", "update", "-y"]): return False
        
        print("\n[*] 安装 dropbear SSH 服务器...")
        if not self._run_command(["apt-get", "install", "-y", "dropbear"]): return False

        print("\n[*] 正在为 'root' 用户设置密码...")
        # 使用管道将密码传递给 chpasswd
        chpasswd_process = subprocess.Popen(['chpasswd'], stdin=subprocess.PIPE, text=True)
        chpasswd_process.communicate(input=f"root:{SSH_PASSWORD}")
        if chpasswd_process.returncode != 0:
            print("✗ 设置 root 密码失败！", file=sys.stderr)
            return False
        print("✓ root 密码设置成功。")

        print("\n[*] 启动 Dropbear SSH 服务...")
        # -E: Log to stderr, -F: Foreground mode (managed by our script)
        # 我们用 Popen 在后台启动它
        self._run_command(["/usr/sbin/dropbear", "-p", "22", "-E", "-F"], capture_output=False)
        print("✓ SSH 服务器已在端口 22 上启动。")
        return True

    def setup_cloudflare_tunnel(self):
        """下载并运行 cloudflared 隧道"""
        print("\n--- 步骤 2: 设置 Cloudflare Tunnel ---")
        if not TUNNEL_TOKEN or "YOUR_LONG_TOKEN" in TUNNEL_TOKEN:
            print("✗ 错误：请在脚本顶部配置你的 TUNNEL_TOKEN！", file=sys.stderr)
            return False

        print("[*] 下载 cloudflared...")
        try:
            url = "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64"
            response = requests.get(url, stream=True)
            response.raise_for_status()
            with open(self.cloudflared_path, 'wb') as f:
                for chunk in response.iter_content(chunk_size=8192):
                    f.write(chunk)
            os.chmod(self.cloudflared_path, 0o755)
            print(f"✓ cloudflared 已下载到: {self.cloudflared_path}")
        except Exception as e:
            print(f"✗ 下载 cloudflared 失败: {e}", file=sys.stderr)
            return False

        print("\n[*] 正在后台启动 Cloudflare Tunnel...")
        command = [
            str(self.cloudflared_path), "tunnel", "--no-autoupdate",
            "run", "--token", TUNNEL_TOKEN
        ]
        self.tunnel_process = self._run_command(command, capture_output=False)
        
        # 等待几秒钟让隧道建立连接
        time.sleep(10)
        
        # 检查进程是否仍在运行
        if self.tunnel_process.poll() is None:
            print("✓ Cloudflare Tunnel 进程已成功启动。")
            return True
        else:
            print("✗ Cloudflare Tunnel 进程启动失败，请检查上面的日志和你的Token。", file=sys.stderr)
            return False
    
    def final_instructions(self):
        """显示最终的连接说明"""
        print("\n" + "="*50)
        print("🎉 部署完成! SSH 隧道正在运行中 🎉")
        print("="*50)
        print("\n下一步操作 (仅需在 Cloudflare 网站上操作一次):")
        print(f"1. 前往 Zero Trust -> Access -> Tunnels，你应该能看到你的隧道状态为 'HEALTHY'。")
        print(f"2. 点击隧道名称 -> 'Public Hostnames' -> 'Add a public hostname'。")
        print(f"   - Subdomain/Path: 填写 '{SSH_DOMAIN.split('.')[0]}' (或你想要的任何子域名)")
        print(f"   - Domain:         选择 '{'.'.join(SSH_DOMAIN.split('.')[1:])}'")
        print(f"   - Service Type:     选择 'SSH'")
        print(f"   - URL:              填写 'localhost:22'")
        print(f"   - 点击 'Save hostname'。")
        print("\n保存后, 你就可以从任何电脑上通过以下命令连接了:")
        print("\n" + "-"*50)
        print(f"  ssh root@{SSH_DOMAIN}")
        print("-"*50 + "\n")
        print(f"当提示时，请输入你设置的密码: '{SSH_PASSWORD}'")

    def cleanup(self):
        """清理资源"""
        print("\n正在清理资源...")
        if self.tunnel_process and self.tunnel_process.poll() is None:
            self.tunnel_process.terminate()
            print("✓ Cloudflare Tunnel 进程已终止。")
        print("✓ Python 脚本资源清理完成。")

def signal_handler(signum, frame):
    """信号处理器，用于优雅地退出"""
    print(f"\n收到信号 {signal.Signals(signum).name}，正在退出...")
    # 全局变量 'manager' 将在 main 函数中被赋值
    if 'manager' in globals():
        manager.cleanup()
    sys.exit(0)

def main():
    # 这一行将 manager 实例暴露给全局，以便信号处理器可以访问它
    global manager
    manager = CloudflareTunnelManager()
    
    # 注册信号处理器，与原脚本逻辑保持一致
    try:
        signal.signal(signal.SIGINT, signal_handler)
        signal.signal(signal.SIGTERM, signal_handler)
    except ValueError:
        print("⚠ 检测到非主线程环境，跳过信号处理器注册。")
    
    try:
        print("=== 基于 Cloudflare Tunnel 的稳定 SSH 连接器 ===")
        
        # 检查并安装 requests 依赖，与原脚本逻辑保持一致
        try:
            import requests
        except ImportError:
            print("检测到未安装 requests 库，正在安装...")
            subprocess.check_call([sys.executable, "-m", "pip", "install", "requests"])
            print("✓ requests 库安装成功")
        
        # 1. 设置 SSH 服务器
        if not manager.setup_ssh_server():
            return False
        
        # 2. 设置并启动 Cloudflare Tunnel
        if not manager.setup_cloudflare_tunnel():
            return False
            
        # 3. 显示最终说明
        manager.final_instructions()
        
        # 4. 保活机制，与原脚本逻辑保持一致
        print("\n📍 脚本将持续运行以保持隧道连接。按 Ctrl+C 停止。")
        print("📍 查看隧道日志: 在 Cloudflare Zero Trust 仪表盘中查看。")
        while True:
            time.sleep(3600)
            print(f"[{time.ctime()}] (保活) SSH 隧道仍在运行中...")
            
        return True
            
    except Exception as e:
        print(f"✗ 程序主流程发生严重错误: {e}", file=sys.stderr)
        return False
    finally:
        manager.cleanup()
    
    return True

if __name__ == "__main__":
    if os.geteuid() != 0:
        print("错误：此脚本需要以root权限运行，因为它需要安装软件和设置密码。", file=sys.stderr)
        sys.exit(1)
    
    success = main()
    sys.exit(0 if success else 1)