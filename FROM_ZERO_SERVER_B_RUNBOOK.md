# Server B 海外 VPS 从零实操文档

> Server B = 海外 VPS。  
> 它负责海外出口、Xray 服务端、NewAPI / Verdaccio / git mirror / marketplace 分发栈。  
> 这份文档假设你已经按 Server A 文档做到：A 上生成了 `wg-server-b.conf`，并且这个文件已经下载到 Windows 桌面。

## 0. 先把这些信息填好

| 名称 | 你要填什么 | 示例 |
| --- | --- | --- |
| Server B 公网 IP | 海外 VPS 的公网 IPv4 | `8.8.8.8` |
| Server B 初始 SSH 用户 | 通常是 `root` | `root` |
| Server B 初始密码 | VPS 面板里设置的密码 | 不要写进文档 |
| Server B 新 SSH 端口 | 建议固定，不要随机 | `22222` |
| Server A 公网 IP | 腾讯云公网 IPv4 | `1.2.3.4` |
| WireGuard 配置文件 | A 生成并下载到 Windows 的文件 | `Desktop\wg-server-b.conf` |
| 仓库地址 | 这个项目的 Git 地址 | `https://github.com/.../bifrost.git` |

文档里的 `<SERVER_B_IP>` 要替换成 Server B 的公网 IP。  
文档里的 `<SERVER_A_IP>` 要替换成 Server A 的公网 IP。  
文档里的 `<REPO_URL>` 要替换成真实仓库地址。  
输入命令时不要保留尖括号。

## 1. 在海外 VPS 控制台放行端口

不同 VPS 面板名字不一样，可能叫：

- Firewall
- Security Group
- Network Firewall
- 防火墙
- 安全组

先放行这些端口：

| 协议 | 端口 | 来源 | 用途 |
| --- | --- | --- | --- |
| TCP | `22` | 你的公网 IP | 第一次登录 |
| TCP | `22222` | 你的公网 IP | 加固后的 SSH |
| TCP | `443` | `0.0.0.0/0` | Xray Reality / HTTPS |

如果后面你在 `--server-b` 里选择了额外服务，比如 3x-ui 或 Hysteria 2，再按脚本输出补充放行端口。  
第一次测试先不要开放一堆无关端口。

## 2. 第一次用 SSH 连上 Server B

在 Windows PowerShell 里执行：

```powershell
ssh root@<SERVER_B_IP>
```

第一次连接如果问：

```text
Are you sure you want to continue connecting?
```

输入：

```text
yes
```

然后输入 VPS 密码。  
密码输入时不会显示，这是正常的。

登录成功后，你会看到类似：

```text
root@vps:~#
```

这表示你现在已经在 Server B 里。

## 3. 在 Server B 上安装基础工具并拉项目

下面命令在 Server B 的 SSH 窗口里执行。

Ubuntu / Debian：

```bash
apt update
apt install -y git curl ca-certificates wireguard-tools
```

Rocky / AlmaLinux / CentOS：

```bash
dnf install -y git curl ca-certificates wireguard-tools
```

拉项目：

```bash
git clone <REPO_URL> /opt/bifrost
cd /opt/bifrost
chmod +x install.sh scripts/*.sh
```

确认目录正确：

```bash
pwd
ls
```

`pwd` 应该是：

```text
/opt/bifrost
```

## 4. 在 Server B 上做云审查

```bash
cd /opt/bifrost
./install.sh --cloud-review
```

这一步只检查，不会删除 VPS 厂商的 agent。  
如果它提示 cloud agent / monitor / security 之类内容，先记录，不要手动删。

## 5. 在 Server B 上做 SSH 加固

```bash
cd /opt/bifrost
./install.sh --security
```

端口输入：

```text
22222
```

脚本要求粘贴 SSH 公钥时，用 Windows PowerShell 查看你的登录公钥：

```powershell
type "$env:USERPROFILE\.ssh\bifrost_root_ed25519.pub"
```

复制整行粘贴进去。

完成后，不要关旧窗口。  
重新打开一个 Windows PowerShell，测试新端口：

```powershell
ssh -i "$env:USERPROFILE\.ssh\bifrost_root_ed25519" -p 22222 root@<SERVER_B_IP>
```

如果新窗口能登录，回到旧窗口执行：

```bash
touch /tmp/ssh-port-change-confirmed
```

从现在开始，连接 Server B 都用：

```powershell
ssh -i "$env:USERPROFILE\.ssh\bifrost_root_ed25519" -p 22222 root@<SERVER_B_IP>
```

## 6. 在 Server B 上部署基础海外网关

这一步会部署 Xray 服务端等基础海外网关能力。  
Server A 后面会要求你填写这里生成的连接参数。

在 Server B 上执行：

```bash
cd /opt/bifrost
./install.sh --server-b
```

脚本一开始会问是否继续，输入：

```text
y
```

后面如果问 Reality SNI、端口、可选组件，第一次测试尽量用默认值。  
如果它要求你输入域名或确认端口，就按你 VPS 的实际情况填。

部署完成后，查看连接信息：

```bash
cat /root/ai-gateway-connection.txt
```

你会看到类似这些字段：

```text
SERVER_IP=8.8.8.8
LISTEN_PORT=443
UUID=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
PUBLIC_KEY=xxxxxxxxxxxxxxxx
SNI=dl.google.com
SHORT_ID=xxxx
```

把这些值保存下来。  
后面回到 Server A 跑 `./install.sh --server-a` 时要用。

## 7. 把 A 生成的 WireGuard 配置上传到 B

这一步在 Windows PowerShell 里执行。

确认你的桌面上已经有：

```text
wg-server-b.conf
```

上传到 Server B：

```powershell
scp -P 22222 -i "$env:USERPROFILE\.ssh\bifrost_root_ed25519" "$env:USERPROFILE\Desktop\wg-server-b.conf" root@<SERVER_B_IP>:/root/wg-server-b.conf
```

然后回到 Server B 的 SSH 窗口，执行：

```bash
install -d -m 0700 /etc/wireguard
cp /root/wg-server-b.conf /etc/wireguard/wg0.conf
chmod 600 /etc/wireguard/wg0.conf
systemctl enable --now wg-quick@wg0
```

验证 `wg0` 是否起来：

```bash
ip link show wg0
wg show
systemctl status wg-quick@wg0 --no-pager
```

如果 `ip link show wg0` 能看到 `wg0`，说明 B 已经接入 A 的 WireGuard 网络。

再测试 B 能不能连到 A 的 WireGuard 地址：

```bash
ping -c 3 10.8.0.1
```

如果 ping 不通，先不要继续启分发栈，回头检查：

- A 的 `./install.sh --vpn` 是否成功
- 腾讯云安全组 UDP `51820` 是否放行
- B 的 `/etc/wireguard/wg0.conf` 里 `Endpoint` 是否是 Server A 公网 IP

## 8. 准备 marketplace 的两把 SSH key

这一步在 Windows PowerShell 里执行。

创建 `bifrost-admin` 写通道 key：

```powershell
ssh-keygen -t ed25519 -f "$env:USERPROFILE\.ssh\bifrost-admin" -C "bifrost-admin"
```

创建 `bifrost-readonly` 读通道 key：

```powershell
ssh-keygen -t ed25519 -f "$env:USERPROFILE\.ssh\bifrost-readonly" -C "bifrost-readonly"
```

上传两个公钥到 Server B：

```powershell
ssh -i "$env:USERPROFILE\.ssh\bifrost_root_ed25519" -p 22222 root@<SERVER_B_IP> "mkdir -p /root/bifrost-keys && chmod 700 /root/bifrost-keys"
scp -P 22222 -i "$env:USERPROFILE\.ssh\bifrost_root_ed25519" "$env:USERPROFILE\.ssh\bifrost-admin.pub" "$env:USERPROFILE\.ssh\bifrost-readonly.pub" root@<SERVER_B_IP>:/root/bifrost-keys/
```

注意：

- `bifrost-admin` 是写通道，用于面板上传 plugin。
- `bifrost-readonly` 是读通道，用于只读状态、日志、磁盘等。
- 不要把它们和 root 登录 key 混用。

## 9. 在 Server B 上启用分发栈

回到 Server B 的 SSH 窗口，执行：

```bash
cd /opt/bifrost
export BIFROST_SERVER_B_WG_IP=10.8.0.2
export BIFROST_ADMIN_SSH_PUBLIC_KEY_FILE=/root/bifrost-keys/bifrost-admin.pub
export BIFROST_READONLY_SSH_PUBLIC_KEY_FILE=/root/bifrost-keys/bifrost-readonly.pub
bash scripts/server-b.sh --enable-distribution
```

如果它立刻报：

```text
wg0 is not active
```

说明第 7 步没成功。先修 `wg0`，不要跳过。

启用完成后，执行诊断：

```bash
cd /opt/bifrost
bash scripts/diagnostics.sh --check distribution
```

## 10. Server B 最小验收

在 Server B 上执行：

```bash
ip link show wg0
systemctl is-active xray
systemctl is-active caddy
systemctl is-active verdaccio
systemctl is-active marketplace-render.path
systemctl is-active upstream-schema-check.timer
```

如果某条输出是：

```text
active
```

说明这个服务正在运行。

看 marketplace 状态文件：

```bash
cat /var/lib/dist/plugins/state.json
```

看 marketplace admin 审计日志是否存在：

```bash
ls -l /var/log/marketplace/admin-audit.log
```

看连接信息文件还在不在：

```bash
cat /root/ai-gateway-connection.txt
```

## 11. 做完 B 后回到 Server A

到这里，Server B 需要给 Server A 两类东西：

第一类是基础海外网关信息，在这里：

```bash
cat /root/ai-gateway-connection.txt
```

第二类是 WireGuard 内网地址，默认是：

```text
10.8.0.2
```

现在回到 `FROM_ZERO_SERVER_A_RUNBOOK.md` 的第 8 步，继续部署 Server A 主线。

## 12. Server B 常见错误

### `scp` 上传失败

先确认你是不是用了新端口：

```powershell
scp -P 22222 -i "$env:USERPROFILE\.ssh\bifrost_root_ed25519" ...
```

不是：

```powershell
scp ...
```

### `wg0 is not active`

先看服务日志：

```bash
journalctl -u wg-quick@wg0 --no-pager -n 80
```

重点检查：

- `/etc/wireguard/wg0.conf` 是否存在
- 文件权限是否是 `600`
- 配置里的 `Endpoint` 是否是 Server A 公网 IP
- 腾讯云是否放行 UDP `51820`

### `--enable-distribution` 提示缺 Docker

正常情况下脚本会尝试安装 Docker。  
如果失败，先看错误日志，不要手动乱装多个 Docker 版本。

### `bifrost-admin` 没启用

检查你运行 `--enable-distribution` 前有没有导出：

```bash
export BIFROST_ADMIN_SSH_PUBLIC_KEY_FILE=/root/bifrost-keys/bifrost-admin.pub
```

检查文件是否存在：

```bash
ls -l /root/bifrost-keys/bifrost-admin.pub
```

