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
| 仓库地址 | 这个项目的 Git 地址 | `https://github.com/ZRainbow1275/bifrost.git` |

文档里的 `<SERVER_B_IP>` 要替换成 Server B 的公网 IP。  
文档里的 `<SERVER_A_IP>` 要替换成 Server A 的公网 IP。  
仓库地址已经写成你的远端仓库：`https://github.com/ZRainbow1275/bifrost.git`。
输入命令时不要保留尖括号。

如果你现在的 Server B 上已经有一个“初步仓库”，比如 `/opt/bifrost` 已存在，但还没有同步到最新远端版本，不要把它当成完全空白机器重新 clone。
这时要先走“已有旧 checkout”的更新路径：先看 `git status --short --branch`，再用 `bash ./install.sh --github-hosts-repair` 和 `git pull --ff-only` 把它拉到最新。

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

先尝试从 GitHub 拉项目：

```bash
git clone https://github.com/ZRainbow1275/bifrost.git /opt/bifrost
cd /opt/bifrost
git status --short --branch
```

新版仓库已经自带脚本可执行权限。不要再执行 `chmod +x install.sh scripts/*.sh`，否则旧版本仓库会把很多脚本标成 `M`，干扰后面的 `git pull` 判断。

截至 `2026-05-21` 的实测结果：海外 VPS 通常可以直接拉 GitHub，但不同线路仍可能短时失败。
如果上面这三行已经成功，就直接跳到“确认目录正确”。
如果 `git clone` 或后面的 `git pull --ff-only` 出现 `GnuTLS recv error (-110)`，不要反复重试，直接按下面的 hosts 或本机上传兜底方案处理。

如果 Server B 是海外 VPS，通常这一步能成功。
如果它也出现类似下面的错误：

```text
fatal: unable to access 'https://github.com/ZRainbow1275/bifrost.git/': GnuTLS recv error (-110): The TLS connection was non-properly terminated.
```

就不要反复重试。可以先改 `/etc/hosts`，如果仍然失败，再从 Windows 本机打包上传。

### 3.1 VPS 也拉不动 GitHub 时：先修改 /etc/hosts

海外 VPS 通常不需要这一步。
只有当 Server B 也拉不动 GitHub 时，才按这里处理。

如果 `/opt/bifrost` 目录已经存在，而且里面已经有最新脚本，先在 Server B 执行：

```bash
cd /opt/bifrost
git status --short --branch
./install.sh --github-hosts-repair
git pull --ff-only
```

如果这里报 `Permission denied`，不要先去改整棵仓库的权限，直接换成：

```bash
bash ./install.sh --github-hosts-repair
```

这通常表示你当前还是旧 checkout，`install.sh` 还没有可执行位。等后面 `git pull` 到最新版本后，再回到正常的 `./install.sh ...` 形式即可。

这条命令会自动备份 `/etc/hosts`，用 DNS-over-HTTPS 查询 `github.com` 和 `raw.githubusercontent.com` 当前可用的 IPv4，只替换 Bifrost 自己维护的 hosts 托管块，然后用 `git ls-remote https://github.com/ZRainbow1275/bifrost.git main` 验证 GitHub 是否真的能访问。
如果当前解析到多个 GitHub 候选 IP，脚本会自动逐个尝试，不再只卡死在第一个 IP 上。

如果你用的是旧 checkout，脚本停在下面这一行很久不动：

```text
Verifying GitHub access: git ls-remote --heads https://github.com/ZRainbow1275/bifrost.git main
```

先按 `Ctrl+C` 退出。然后用旧脚本的跳过验证模式，只修 `/etc/hosts`，不要让旧脚本继续卡在 `git ls-remote`：

```bash
cd /opt/bifrost
BIFROST_GITHUB_HOSTS_SKIP_GIT_CHECK=1 bash ./install.sh --github-hosts-repair
timeout 20s git ls-remote --heads https://github.com/ZRainbow1275/bifrost.git main
echo "git-check-exit=$?"
```

这里要看最后一行退出码：

- `git-check-exit=0`，并且上面出现 `refs/heads/main`，说明 GitHub 已经能连上，可以继续 `git pull --ff-only`。
- `git-check-exit=124`，说明 20 秒超时，先不要继续 `git pull`。
- 其他非 `0` 数字，说明 GitHub 连接还是失败，先不要继续 `git pull`。

如果这条 `timeout 20s git ls-remote ...` 失败或超时，把从 `timeout 20s ...` 到 `git-check-exit=...` 的完整输出贴出来。新版脚本已经给 Git 验证加了超时，拉到新版后不会再无限卡住。

如果这里直接出现下面这种输出：

```text
2026-05-22 14:50:33 [ERROR] 未知参数: --github-hosts-repair
```

这不是你输错了，而是服务器上的项目代码还太旧，还没有这个命令。
不要在旧版本里继续找这个参数。先按下面的手动 hosts 修复或引导修复命令，把 GitHub 访问先修通，再把代码 `git pull --ff-only` 到最新版本，然后再回来执行 `./install.sh --github-hosts-repair`。

#### 3.1.1 `git pull` 已经能联网，但被本地改动卡住

如果你已经修好了 hosts，`git pull --ff-only` 也能连上远端了，但又出现下面这种报错：

```text
error: Your local changes to the following files would be overwritten by merge:
        install.sh
        scripts/security.sh
Please commit your changes or stash them before you merge.
Aborting
```

这说明不是网络问题，而是服务器本地已经改过代码。不要直接删文件，也不要上来就 `git reset --hard`。先把现场备份下来，再临时收起来，然后再拉最新代码。

在 Server B 的 SSH 窗口里按这个顺序做：

```bash
sudo -i
cd /opt/bifrost

git status --short

backup_dir="/root/bifrost-local-backup/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$backup_dir"
cp install.sh scripts/security.sh "$backup_dir"/
git diff -- install.sh scripts/security.sh > "$backup_dir/local-changes.diff"

git stash push -m "bifrost local changes before pull" -- install.sh scripts/security.sh
git pull --ff-only

git status --short --branch
./install.sh --github-hosts-repair
```

如果你后面想看那份本地改动，备份都在：

```bash
/root/bifrost-local-backup/
```

如果 `git status --short --branch` 看到一大串下面这种 `M scripts/*.sh`：

```text
 M install.sh
 M scripts/security.sh
 M scripts/server-a.sh
 M scripts/server-b.sh
```

并且你前面执行过 `chmod +x install.sh scripts/*.sh`，这通常只是“文件权限变化”，不是代码内容真的被你改了。
如果还看到 `M configs/sysctl/hardening.conf`，这是旧版安全脚本曾把运行时 sysctl 配置反写回项目目录造成的；新版脚本已经修掉这个行为。

为了不丢现场，先备份 diff，再恢复这些仓库文件到 Git 版本：

```bash
cd /opt/bifrost

backup_dir="/root/bifrost-local-backup/$(date +%Y%m%d-%H%M%S)-dirty-tree"
mkdir -p "$backup_dir"
git diff > "$backup_dir/all-local-changes.diff"

git restore -- configs/sysctl/hardening.conf install.sh scripts/*.sh
git pull --ff-only
./install.sh --github-hosts-repair
```

这段命令不会删除 `/etc/hosts`、`/etc/ssh/sshd_config`、`/etc/sysctl.d/` 这些真正的系统配置；它只把 `/opt/bifrost` 仓库里的文件恢复成远端版本。

如果你现在的 Server B 项目目录还没有这个新脚本，或者 `git clone` 第一次就失败导致 `/opt/bifrost` 还不存在，就按下面的手动方式做一次。

先在你的 Windows 浏览器里打开：

```text
https://www.ipaddress.com/
```

在网站里分别查询：

```text
github.com
raw.githubusercontent.com
```

你会查到类似这样的 IPv4 地址：

```text
140.82.112.4 github.com
185.199.108.133 raw.githubusercontent.com
```

上面只是示例。实际操作时，以你当场查到的 IP 为准。

回到 Server B 的 SSH 窗口，执行下面命令。
它会让你输入两次 IP，把你刚才查到的 IP 粘贴进去：

```bash
read -rp "请输入 github.com 的 IPv4: " GITHUB_IP
read -rp "请输入 raw.githubusercontent.com 的 IPv4: " RAW_GITHUB_IP

cp /etc/hosts "/etc/hosts.bak.$(date +%Y%m%d-%H%M%S)"
sed -i '/# BIFROST-GITHUB-HOSTS-BEGIN/,/# BIFROST-GITHUB-HOSTS-END/d; /[[:space:]]github\.com$/d; /[[:space:]]raw\.githubusercontent\.com$/d' /etc/hosts
printf '\n# BIFROST-GITHUB-HOSTS-BEGIN\n%s github.com\n%s raw.githubusercontent.com\n# BIFROST-GITHUB-HOSTS-END\n' "$GITHUB_IP" "$RAW_GITHUB_IP" >> /etc/hosts
getent hosts github.com
getent hosts raw.githubusercontent.com
```

确认 `getent hosts` 能显示你刚写进去的 IP 后，再重新拉项目：

```bash
rm -rf /opt/bifrost
git clone https://github.com/ZRainbow1275/bifrost.git /opt/bifrost
cd /opt/bifrost
git status --short --branch
```

如果还是失败，继续下一节，从 Windows 本机打包上传。

后续如果你已经有 `/opt/bifrost`，只是执行 `git pull --ff-only` 失败，优先回到本节开头执行：

```bash
cd /opt/bifrost
./install.sh --github-hosts-repair
git pull --ff-only
```

如果当前服务器上的项目代码太旧，没有 `--github-hosts-repair` 这个命令，或者脚本修复后还是拉不动，再走下一节的本机上传方案。
本机上传会用你 Windows 上的最新项目包覆盖服务器上的 `/opt/bifrost`，效果等同于把服务器代码更新到本机当前版本。

### 3.2 VPS 改 hosts 后仍然拉不动：从 Windows 本机上传项目

先在你的 Windows PowerShell 里执行。这里假设你的本机项目目录是：

```text
D:\Desktop\CREATOR FIVE
```

执行：

```powershell
cd "D:\Desktop\CREATOR FIVE"
git archive --format=tar.gz -o "$env:USERPROFILE\Desktop\bifrost-main.tar.gz" HEAD
scp "$env:USERPROFILE\Desktop\bifrost-main.tar.gz" root@<SERVER_B_IP>:/tmp/bifrost-main.tar.gz
```

如果你已经把 Server B 的 SSH 端口改成了 `22222`，上传命令改成：

```powershell
scp -P 22222 -i "$env:USERPROFILE\.ssh\bifrost_root_ed25519" "$env:USERPROFILE\Desktop\bifrost-main.tar.gz" root@<SERVER_B_IP>:/tmp/bifrost-main.tar.gz
```

上传完成后，回到 Server B 的 SSH 窗口，执行：

```bash
rm -rf /opt/bifrost
mkdir -p /opt/bifrost
tar -xzf /tmp/bifrost-main.tar.gz -C /opt/bifrost
cd /opt/bifrost
git status --short --branch
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

这一轮加固的目标是：服务器不再识别密码登录，只接受 SSH 公钥登录。
脚本会把 SSH 配置改成下面这种效果：

```text
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
AuthenticationMethods publickey
PubkeyAuthentication yes
PermitRootLogin prohibit-password
```

完成后，不要关旧窗口。  
重新打开一个 Windows PowerShell，测试新端口：

```powershell
ssh -i "$env:USERPROFILE\.ssh\bifrost_root_ed25519" -p 22222 root@<SERVER_B_IP>
```

如果新窗口能登录，回到旧窗口执行：

```bash
touch /tmp/ssh-port-change-confirmed
```

确认后，在 Server B 的 SSH 窗口里检查一次实际生效配置：

```bash
sshd -T | grep -E '^(passwordauthentication|kbdinteractiveauthentication|authenticationmethods|pubkeyauthentication|permitrootlogin) '
```

你应该看到类似：

```text
passwordauthentication no
kbdinteractiveauthentication no
authenticationmethods publickey
pubkeyauthentication yes
permitrootlogin prohibit-password
```

再做一个反向验证：新开 Windows PowerShell，强制不用密钥、只尝试密码登录：

```powershell
ssh -o PubkeyAuthentication=no -o PreferredAuthentications=password -p 22222 root@<SERVER_B_IP>
```

这条命令应该登录失败。
如果它还能让你用密码登录成功，立刻停下，不要继续后面的部署。

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
