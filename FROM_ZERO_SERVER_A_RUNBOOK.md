# Server A 腾讯云从零实操文档

> Server A = 腾讯云国内服务器。  
> 它负责入口、Caddy、管理面板、WireGuard 网关，以及把流量转到 Server B。  
> 这份文档按“第一次接触服务器也能照着做”的方式写。不要一口气复制整篇，每次只复制一个代码块。

## 0. 先把这些信息填在纸上

先不要开终端，先把下面这些信息准备好。

| 名称 | 你要填什么 | 示例 |
| --- | --- | --- |
| Server A 公网 IP | 腾讯云实例的公网 IPv4 | `1.2.3.4` |
| Server A 初始 SSH 用户 | 腾讯云 Ubuntu 通常是 `ubuntu`，不是 `root` | `ubuntu` |
| Server A 初始登录方式 | 腾讯云控制台给你的密码或密钥 | 不要写进文档 |
| Server A 新 SSH 端口 | 建议先固定一个，不要随机 | `22222` |
| Server B 公网 IP | 海外 VPS 的公网 IPv4 | `8.8.8.8` |
| 仓库地址 | 这个项目的 Git 地址 | `https://github.com/ZRainbow1275/bifrost.git` |
| 你的本机 | 你现在操作的 Windows 电脑 | PowerShell |

文档里的 `<SERVER_A_IP>` 要替换成 Server A 的公网 IP。  
文档里的 `<SERVER_A_LOGIN_USER>` 默认先写 `ubuntu`。  
文档里的 `<SERVER_B_IP>` 要替换成 Server B 的公网 IP。  
仓库地址已经写成你的远端仓库：`https://github.com/ZRainbow1275/bifrost.git`。
输入命令时不要保留尖括号。

## 1. 在你的 Windows 电脑上准备 SSH key

先在 Windows 上打开 PowerShell。

打开方法：

1. 按键盘 `Win`
2. 输入 `PowerShell`
3. 点开 `Windows PowerShell`

先创建一把专门给服务器登录用的 SSH key：

```powershell
ssh-keygen -t ed25519 -f "$env:USERPROFILE\.ssh\bifrost_root_ed25519" -C "bifrost-root"
```

它会问你：

```text
Enter passphrase
```

新手测试阶段可以直接按回车两次，表示暂时不设置 key 密码。  
如果你已经熟悉 SSH，也可以设置一个 passphrase。

看一下公钥内容：

```powershell
type "$env:USERPROFILE\.ssh\bifrost_root_ed25519.pub"
```

你会看到一长行，类似：

```text
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI... bifrost-root
```

后面脚本让你粘贴 SSH 公钥时，就粘贴这一整行。

## 2. 在腾讯云控制台先放行端口

先在腾讯云网页控制台操作，不是在服务器里操作。

进入路径大概是：

1. 腾讯云控制台
2. 云服务器 CVM
3. 找到 Server A 实例
4. 点它绑定的安全组
5. 入站规则

至少先放行这些端口：

| 协议 | 端口 | 来源 | 用途 |
| --- | --- | --- | --- |
| TCP | `22` | 你的公网 IP | 第一次登录 |
| TCP | `22222` | 你的公网 IP | 加固后的 SSH |
| TCP | `80` | `0.0.0.0/0` | 申请证书 / HTTP |
| TCP | `443` | `0.0.0.0/0` | HTTPS 入口 |
| UDP | `51820` | `0.0.0.0/0` | WireGuard |

如果你不知道自己的公网 IP，可以在浏览器打开：

```text
https://ipinfo.io/ip
```

如果你暂时不知道怎么限制来源，可以先用 `0.0.0.0/0` 测通，跑通后再收紧。  
但 SSH 端口长期不建议对全网开放。

## 3. 第一次用 SSH 连上 Server A

回到 Windows PowerShell。

腾讯云 Ubuntu 镜像一般不给 root 密码，默认登录用户通常是 `ubuntu`。  
所以第一次先这样连：

```powershell
ssh ubuntu@<SERVER_A_IP>
```

如果你的腾讯云镜像明确写的是其他用户，就把 `ubuntu` 换成控制台显示的用户名。  
如果你用的是密钥登录，还需要加 `-i`，例如：

```powershell
ssh -i "$env:USERPROFILE\.ssh\你的腾讯云密钥文件" ubuntu@<SERVER_A_IP>
```

第一次连接会问：

```text
Are you sure you want to continue connecting (yes/no/[fingerprint])?
```

输入：

```text
yes
```

然后输入腾讯云服务器密码。  
注意：你输入密码时屏幕不会显示星号，这是正常的。

登录成功后，你会看到类似：

```text
ubuntu@VM-xxx:~$
```

这表示你现在已经在 Server A 里面了。

这个项目的安装脚本需要 root 权限。  
所以登录进去后，先切到 root：

```bash
sudo -i
```

如果它问密码，就输入腾讯云给 `ubuntu` 用户的密码。  
成功后提示符会变成类似：

```text
root@VM-xxx:~#
```

从这里开始，后面的服务器命令都在这个 root 窗口里执行。

## 4. 在 Server A 上安装基础工具并拉项目

下面命令是在 Server A 的 SSH 窗口里执行，不是在 Windows PowerShell 里执行。

先确认系统：

```bash
cat /etc/os-release
```

如果是 Ubuntu / Debian，执行：

```bash
apt update
apt install -y git curl ca-certificates
```

如果是 Rocky / AlmaLinux / CentOS，执行：

```bash
dnf install -y git curl ca-certificates
```

然后拉项目：

```bash
git clone https://github.com/ZRainbow1275/bifrost.git /opt/bifrost
cd /opt/bifrost
chmod +x install.sh scripts/*.sh
```

确认你已经在项目目录里：

```bash
pwd
ls
```

`pwd` 应该输出：

```text
/opt/bifrost
```

`ls` 应该能看到：

```text
install.sh
scripts
bifrost-api
bifrost-api-web
```

## 5. 在 Server A 上先做云审查

先执行：

```bash
cd /opt/bifrost
./install.sh --cloud-review
```

这一步只检查，不会删除腾讯云监控、安全代理或云初始化组件。

如果看到 Tencent、qcloud、agent、monitoring 之类提示，不要慌。  
它的意思是：脚本发现这台机器可能有腾讯云组件，需要你知道它们存在。  
这些组件可能负责云监控、控制台救援、密钥注入、审计或备份。

新手阶段不要手动删除这些东西。  
我们先跑项目，不先破坏云厂商的救援链路。

## 6. 在 Server A 上做 SSH 加固

还在 Server A 里执行：

```bash
cd /opt/bifrost
./install.sh --security
```

脚本会问 SSH 端口。  
这里不要用随机默认值，输入你前面在腾讯云安全组放行过的端口：

```text
22222
```

脚本会让你粘贴 SSH 公钥。  
回到 Windows PowerShell 执行：

```powershell
type "$env:USERPROFILE\.ssh\bifrost_root_ed25519.pub"
```

复制输出的整行，粘贴到服务器脚本里。

注意：当前项目的安全脚本默认把这把公钥写进 `/root/.ssh/authorized_keys`。  
所以第一次是 `ubuntu` 登录，但加固后的运维登录会改成 `root + SSH key`。

脚本完成后，不要关闭当前 SSH 窗口。

重新打开一个新的 Windows PowerShell，测试新端口登录：

```powershell
ssh -i "$env:USERPROFILE\.ssh\bifrost_root_ed25519" -p 22222 root@<SERVER_A_IP>
```

如果新窗口能登录成功，再回到旧 SSH 窗口执行：

```bash
touch /tmp/ssh-port-change-confirmed
```

这一步很重要。  
脚本有 5 分钟自动回滚保护，如果你不确认，它可能会把 SSH 配置回滚。

从现在开始，连接 Server A 都用：

```powershell
ssh -i "$env:USERPROFILE\.ssh\bifrost_root_ed25519" -p 22222 root@<SERVER_A_IP>
```

如果这条 `root@<SERVER_A_IP>` 测试失败，但旧的 `ubuntu` 窗口还开着，不要关闭旧窗口。  
先停下来排查，不要继续关密码登录后的操作。

## 7. 先在 Server A 上部署 WireGuard

Server B 后面要通过 WireGuard 接进来。  
所以 A 必须先把 VPN 网关建出来。

在 Server A 里执行：

```bash
cd /opt/bifrost
./install.sh --vpn
```

如果脚本问你选择 VPN 类型，第一次测试优先选择最普通的 WireGuard / standalone WireGuard。  
如果它没有问，按脚本默认继续。

完成后，给 Server B 创建一个 WireGuard 配置：

```bash
cd /opt/bifrost
bash scripts/vpn.sh create_user server-b
```

看一下配置文件是否生成：

```bash
ls -l /etc/bifrost/vpn/users/server-b/
```

你应该能看到：

```text
wg-server-b.conf
```

把这个文件下载到你的 Windows 桌面。  
在 Windows PowerShell 里执行，不是在服务器里执行：

```powershell
scp -P 22222 -i "$env:USERPROFILE\.ssh\bifrost_root_ed25519" root@<SERVER_A_IP>:/etc/bifrost/vpn/users/server-b/wg-server-b.conf "$env:USERPROFILE\Desktop\wg-server-b.conf"
```

确认桌面上出现了：

```text
wg-server-b.conf
```

做到这里，Server A 先暂停。  
现在去执行 `FROM_ZERO_SERVER_B_RUNBOOK.md`，把 Server B 做到 `wg0` 已经起来，并且分发栈已经启用。

## 8. Server B 做完后，回到 Server A 跑主部署

当 Server B 已经完成这些事情后，再回到这里：

- Server B 能 SSH 登录
- Server B 已经跑过 `./install.sh --server-b`
- Server B 的 `/root/ai-gateway-connection.txt` 已经生成
- Server B 已经导入 `wg-server-b.conf`
- Server B 上 `wg0` 已经是 active
- Server B 已经跑过 `scripts/server-b.sh --enable-distribution`

先从 Server B 文档里拿到这些值：

| A 端脚本会问什么 | 从 B 的哪个字段复制 |
| --- | --- |
| Server B IP address | `SERVER_IP` |
| Server B port | `LISTEN_PORT` |
| UUID | `UUID` |
| Reality public key | `PUBLIC_KEY` |
| SNI / Server name | `SNI` |
| Short ID | `SHORT_ID` |

然后在 Server A 里执行：

```bash
cd /opt/bifrost
export BIFROST_SERVER_A_TLS_MODE=ip
export BIFROST_SERVER_A_PUBLIC_IP=<SERVER_A_IP>
export BIFROST_ACME_EMAIL=<你的邮箱>
export BIFROST_SERVER_B_WG_IP=10.8.0.2
export BIFROST_SERVER_A_NEWAPI_MODE=distribution
export BIFROST_SKIP_DEPRECATION_WAIT=1
./install.sh --server-a
```

如果脚本问 Server B 信息，就按上表从 `/root/ai-gateway-connection.txt` 里复制。

如果脚本再次问 SSH 端口，继续填：

```text
22222
```

如果脚本问是否部署 VPN，而你已经在第 7 步部署过，可以选 `n`。  
如果你不确定，也可以选 `y`，但不要删除已有的 `server-b` 用户配置。

## 9. 部署 Bifrost API 管理平台

当前脚本有一个现实限制：`./install.sh --bifrost-api` 会先检查 Server A 本机 `127.0.0.1:3000` 是否能访问 NewAPI。  
但 distribution 模式下 NewAPI 在 Server B 的 `10.8.0.2:3000`。

所以第一次实操测试时，先在 A 上做一个本机转发：

```bash
apt install -y socat
nohup socat TCP-LISTEN:3000,bind=127.0.0.1,fork,reuseaddr TCP:10.8.0.2:3000 >/var/log/bifrost-newapi-forward.log 2>&1 &
curl -fsS http://127.0.0.1:3000/api/status
```

如果你的 Server A 不是 Ubuntu / Debian，而是 Rocky / AlmaLinux / CentOS，把第一行换成：

```bash
dnf install -y socat
```

如果最后一行能输出 NewAPI 状态，再执行：

```bash
cd /opt/bifrost
./install.sh --bifrost-api
```

脚本完成时会打印：

```text
Admin Key: xxxxx
```

把这个 `Admin Key` 复制保存到你自己的密码管理器或临时记事本。  
后面访问管理接口要用 `X-Admin-Key`。

## 10. 部署前端面板

先确认 Node 和 pnpm：

```bash
node --version
pnpm --version
```

面板需要：

- Node `>=20`
- pnpm `>=9`

如果没有 Node/pnpm，先安装。Ubuntu 常见做法：

```bash
curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
apt install -y nodejs
npm install -g pnpm
```

然后构建并部署面板：

```bash
cd /opt/bifrost
pnpm -C bifrost-api-web install --frozen-lockfile
pnpm -C bifrost-api-web build
./install.sh --deploy-panel
```

确认面板文件已经放好：

```bash
test -f /var/www/bifrost-api-web/dist/index.html && echo "panel ok"
```

## 11. Server A 最小验收

在 Server A 上执行：

```bash
systemctl is-active caddy
systemctl is-active netdata
curl -fsS http://127.0.0.1:19999/api/v1/info | head
curl -fsS http://127.0.0.1:8000/health
```

如果你已经有域名，比如 `panel.example.com`，再在你的 Windows PowerShell 里测试：

```powershell
curl.exe -I https://panel.example.com/
```

如果还没有域名，先不要卡在域名这一步，先用上面的本机检查确认服务活着。

## 12. Server A 常见错误

### 连接不上 SSH

先检查你是不是还在用旧端口：

```powershell
ssh ubuntu@<SERVER_A_IP>
```

加固后应该用：

```powershell
ssh -i "$env:USERPROFILE\.ssh\bifrost_root_ed25519" -p 22222 root@<SERVER_A_IP>
```

如果还不行，去腾讯云安全组确认 `22222` 是否放行。

### `--cloud-review` 发现腾讯云 agent

这是正常的。  
它只是提示你机器上有云厂商组件，不代表失败。  
新手测试不要直接删除。

### `--bifrost-api` 提示 NewAPI 不可用

先确认 A 能访问 B 的 NewAPI：

```bash
curl -fsS http://10.8.0.2:3000/api/status
```

再确认 A 本机 3000 转发是否存在：

```bash
curl -fsS http://127.0.0.1:3000/api/status
```

如果第二条失败，重新执行第 9 步的 `socat` 转发。
