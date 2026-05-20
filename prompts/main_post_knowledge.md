---
title: "VPS 基本安全措施"
source_url: "https://linux.do/t/topic/267502"
source_local_html: "index.html"
scope: "主贴知识整理，不包含讨论回复"
target_os: "Ubuntu 24.04 LTS 为主，其他 Linux 发行版按思路调整"
audience: "AI 检索、问答、运维安全基线生成"
license_note: "原帖除特别声明外为 CC BY-NC-SA 4.0；其中证书泄露源站 IP 相关内容按原帖说明为 CC BY-SA 4.0；UFW-Docker 方案按原帖说明引自 GPL-3.0 项目。"
---

# VPS 基本安全措施：AI 可读知识整理

## 1. 核心目标

VPS 与虚拟主机不同，VPS 用户通常拥有完整系统权限，也承担服务器安全责任。本文目标不是实现“绝对安全”，而是让服务器不容易被自动化扫描、弱口令攻击、默认配置和误暴露服务攻破。

基本安全策略可以概括为：

- 最小权限：日常不用 `root`，需要管理时再通过 `sudo` 提权。
- 减少暴露面：只开放确实需要的端口，SSH 和管理面板尽量限制来源 IP。
- 强认证：SSH 使用密钥，禁用密码登录，至少禁用 `root` 密码远程登录。
- 可观测：记录登录、记录防火墙命中、监控异常。
- 持续更新：保持系统和关键服务有安全补丁。
- 隔离部署：业务服务优先容器化，内部组件只在内部网络暴露。
- 隐藏源站：CDN 后的源站尽量只允许 CDN 回源 IP 访问。

## 2. 基线清单

初次拿到 VPS 后建议按以下顺序处理：

1. 创建非 `root` 管理用户，并加入 `sudo` 组。
2. 修改 `root` 和新用户密码，密码至少 16 位随机大小写字母加数字。
3. 配置 SSH：禁用 `root` 密码远程登录，优先启用密钥登录，必要时修改端口。
4. 检查 `/etc/ssh/sshd_config.d/` 是否存在云厂商覆盖配置。
5. 使用 `sshd -T` 验证最终生效配置。
6. 启用 `fail2ban` 防暴力破解。
7. 配置 UFW：默认拒绝入站、允许出站，只放行必要端口。
8. 可选：限制 SSH 来源 IP、禁止 ping、设置登录通知。
9. 定期运行系统更新，Ubuntu 可考虑启用 Ubuntu Pro。
10. 如使用 CDN，源站 80/443 只允许 CDN CIDR 访问。
11. 如使用 Docker，避免把数据库、Redis、管理面板直接暴露到公网。
12. 管理面板、WAF 控制台优先通过 WireGuard 等 VPN 访问。

## 3. 账户与 SSH 安全

### 3.1 创建非 root 管理账户

创建带 home 目录、可使用 `sudo`、默认 shell 为 Bash 的用户：

```bash
useradd -m -G sudo -s /bin/bash <username>
passwd <username>
```

建议同时修改 `root` 密码。部分云厂商会通过邮件发送初始密码，默认密码或邮件明文流转都不适合作为长期凭证。

### 3.2 禁用 root SSH 密码登录

编辑 SSH 配置：

```bash
sudo vim /etc/ssh/sshd_config
```

推荐设置：

```sshconfig
PermitRootLogin prohibit-password
```

重启 SSH：

```bash
sudo systemctl restart ssh
```

说明：

- `PermitRootLogin prohibit-password` 禁止 `root` 通过密码远程登录，但保留密钥登录能力。
- 直接设置为 `PermitRootLogin no` 更严格，但故障救援时可能不方便。
- 如果服务器需要 VNC、IPMI 或云控制台救援，保留本地 `root` 登录能力更稳妥。

### 3.3 修改 SSH 端口

直接编辑：

```bash
sudo vim /etc/ssh/sshd_config
```

设置示例：

```sshconfig
Port 2233
```

重启：

```bash
sudo systemctl restart ssh.service
```

注意事项：

- 修改端口后，当前 SSH 会话通常不会立即断开。应新开一个连接测试新端口能否登录，再关闭旧连接。
- 修改 SSH 端口后，防火墙和 `fail2ban` 的 SSH jail 端口也要同步修改。
- Ubuntu 22.10 到 23.10 默认可能使用 `ssh.socket` 套接字激活，单改 `sshd_config` 可能不生效。

Ubuntu 22.10、23.04、23.10 的 socket 配置思路：

```bash
sudo mkdir -p /etc/systemd/system/ssh.socket.d
sudo vim /etc/systemd/system/ssh.socket.d/listen.conf
sudo systemctl daemon-reload
sudo systemctl restart ssh.socket
sudo systemctl restart ssh.service
```

`listen.conf` 示例：

```ini
[Socket]
ListenStream=
ListenStream=2233
```

如果不需要 socket 激活，可以改回普通 service 管理方式：

```bash
sudo systemctl disable --now ssh.socket
sudo systemctl enable --now ssh.service
```

配置迁移时可清理旧 socket 覆盖项：

```bash
sudo systemctl disable --now ssh.socket
rm -f /etc/systemd/system/ssh.service.d/00-socket.conf
rm -f /etc/systemd/system/ssh.socket.d/addresses.conf
sudo systemctl daemon-reload
sudo systemctl enable --now ssh.service
```

### 3.4 使用 sshd_config.d 管理自定义配置

建议在 `/etc/ssh/sshd_config.d/` 新建独立 `.conf` 文件，而不是直接改 `/etc/ssh/sshd_config`。这样可以减少 OpenSSH 更新时的配置冲突。

检查云厂商是否放置了覆盖配置：

```bash
sudo ls /etc/ssh/sshd_config.d/*.conf
```

如果某个厂商配置会覆盖你的设置，可先备份重命名：

```bash
sudo mv /etc/ssh/sshd_config.d/xxx.conf /etc/ssh/sshd_config.d/xxx.conf.bak
```

验证最终生效配置：

```bash
sudo sshd -T | grep -i "PermitRootLogin"
sudo sshd -T | grep -i "PasswordAuthentication"
sudo sshd -T | grep -i "Port"
```

`prohibit-password` 可能显示为 `without-password`，这是 OpenSSH 的兼容别名，属于正常现象。

### 3.5 SSH 密钥登录

在 Windows PowerShell 中生成 Ed25519 密钥：

```powershell
ssh-keygen -t ed25519
```

默认密钥位置通常是：

```text
C:\Users\<user>\.ssh\id_ed25519
C:\Users\<user>\.ssh\id_ed25519.pub
```

将公钥内容写入 VPS 上的：

```bash
vim ~/.ssh/authorized_keys
```

SSH 配置建议：

```sshconfig
PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys
PasswordAuthentication no
```

重启：

```bash
sudo systemctl restart ssh
```

注意：禁用密码登录前必须确认密钥登录已测试成功。

### 3.6 运行命令使用绝对路径

在高风险环境中，运行敏感命令时使用绝对路径可以减少 `PATH` 被污染导致误执行恶意程序的风险。

示例：

```bash
/usr/bin/su
/usr/bin/sudo
/usr/bin/ssh
```

## 4. 防暴力破解与登录通知

### 4.1 Fail2ban 防 SSH 暴力破解

安装：

```bash
sudo apt install fail2ban
```

自定义配置文件：

```bash
sudo vim /etc/fail2ban/jail.local
```

示例：

```ini
[sshd]
ignoreip = 127.0.0.1/8
enabled = true
filter = sshd
port = 22
maxretry = 5
findtime = 300
bantime = 600
action = %(action_)s[port="%(port)s", protocol="%(protocol)s", logpath="%(logpath)s", chain="%(chain)s"]
banaction = iptables-multiport
logpath = /var/log/auth.log
```

字段含义：

- `ignoreip`：白名单。
- `port`：SSH 端口，改过 SSH 端口必须同步。
- `maxretry`：最大失败次数。
- `findtime`：统计窗口秒数。
- `bantime`：封禁时间，`-1` 为永久封禁，不建议默认永久。
- `logpath`：SSH 登录日志路径。

### 4.2 SSH 登录通知

可以通过 PAM 在 SSH 会话建立时触发脚本，例如发送企业微信机器人通知。

编辑：

```bash
sudo vim /etc/pam.d/sshd
```

添加：

```text
session    optional    pam_exec.so /opt/scripts/login_notify.sh
```

示例脚本要点：

- 只在 `PAM_TYPE=open_session` 时发送通知。
- 记录登录用户、来源 IP、主机名、公网 IP、登录时间。
- HTTP 请求设置连接超时和总超时，避免登录流程卡住。
- Webhook URL 必须替换成自己的地址，不要把真实 key 写入公开文件。

## 5. UFW 防火墙

### 5.1 默认策略

```bash
sudo ufw default allow outgoing
sudo ufw default deny incoming
```

查看规则：

```bash
sudo ufw status
sudo ufw status numbered
```

启用前必须先放行 SSH 端口，否则可能把自己锁在服务器外。

```bash
sudo ufw allow 22/tcp
sudo ufw enable
```

### 5.2 常见规则写法

允许入站：

```bash
sudo ufw allow in 22/tcp
sudo ufw allow 22
```

允许出站：

```bash
sudo ufw allow out 22/tcp
```

拒绝端口：

```bash
sudo ufw deny 22
```

允许端口范围：

```bash
sudo ufw allow <start_port>:<end_port>
```

允许多个端口时要指定协议：

```bash
sudo ufw allow from <ip> to any proto tcp port 80,443
```

允许特定来源访问 SSH：

```bash
sudo ufw allow from <ip_or_cidr> to any proto tcp port 22
```

添加注释：

```bash
sudo ufw allow from <ip> to any proto tcp port 80,443 comment "web access"
```

删除规则：

```bash
sudo ufw delete allow 22
sudo ufw delete <number>
```

重载、关闭、重置：

```bash
sudo ufw reload
sudo ufw disable
sudo ufw reset
```

重置前建议先关闭 UFW，并确认不会丢失必要规则。

### 5.3 日志记录

默认 UFW 主要记录被拒绝数据包。若希望记录某服务的成功连接，可以在 `allow` 后加 `log`。

```bash
sudo ufw allow log 22/tcp
```

### 5.4 禁止 ping

UFW 没有直接的 `deny icmp` 命令。IPv4 可修改：

```text
/etc/ufw/before.rules
```

将 ICMP Echo Request 相关规则改为：

```text
-A ufw-before-input -p icmp --icmp-type echo-request -j DROP
-A ufw-before-forward -p icmp --icmp-type echo-request -j DROP
```

IPv6 可修改：

```text
/etc/ufw/before6.rules
```

仅针对 ping 的示例：

```text
-A ufw6-before-output -p icmpv6 --icmpv6-type echo-request -j DROP
-A ufw6-before-output -p icmpv6 --icmpv6-type echo-reply -j DROP
```

注意：不要随意禁掉全部 ICMPv6。IPv6 依赖部分 ICMPv6 功能，误删可能导致网络异常。

### 5.5 限定 SSH 登录 IP

如果办公网络或跳板网络有固定 IP，推荐只允许该 IP/CIDR 访问 SSH：

```bash
sudo ufw allow from <trusted_ip_or_cidr> to any proto tcp port <ssh_port>
```

没有固定公网 IP 时，可考虑：

- 使用云厂商控制台或云终端。
- 使用厂商安全组控制来源 IP。
- 使用专用跳板机、VPN、WireGuard。
- 如果云终端服务有固定出口 IP 段，可将这些 CIDR 加入白名单。

## 6. 系统更新与 Ubuntu Pro

### 6.1 日常更新

建议定期执行：

```bash
sudo apt update && sudo apt upgrade
```

Ubuntu 默认会自动安装部分安全更新，所以不必过度频繁，但仍应定期登录检查。

### 6.2 Ubuntu Pro

Ubuntu Pro 个人可免费绑定有限数量机器，主要价值是扩展安全维护和更广的软件包 CVE 修复覆盖。

启用步骤：

1. 创建 Ubuntu One 账户。
2. 在 Ubuntu Pro Dashboard 获取 token。
3. 在 VPS 上执行：

```bash
sudo pro attach <YOUR_TOKEN>
sudo apt update && sudo apt upgrade
```

## 7. 隐藏源站与证书安全

### 7.1 源站 IP 隐藏的边界

隐藏公网 IP 不是所有 VPS 的必要需求，但对被 CDN 代理的网站很常见。目标是避免攻击者绕过 CDN 直接打源站。

风险来源包括：

- 证书透明日志或默认证书暴露域名关系。
- 直接访问 IP 时服务器返回真实站点证书。
- 攻击者携带正确 `server_name` 遍历 IP 段，测试域名与 IP 是否匹配。
- CDN 相关产品本身也可能从 CDN IP 段向源站发起请求。

### 7.2 防止直接访问 IP 暴露域名证书

旧方法：为 IP 申请单独证书，并将默认站点配置为访问 IP 时返回空响应或关闭连接。

Nginx 默认站点示例思路：

```nginx
server {
    listen 80;
    listen 443 ssl http2 default_server;
    server_name ip;

    ssl_certificate /etc/nginx/ip-certificate/certificate.crt;
    ssl_certificate_key /etc/nginx/ip-certificate/private.key;

    root /var/www/html/;
    index index.html;
    return 444;
}
```

检查配置：

```bash
nginx -t
sudo systemctl restart nginx
```

Nginx 1.19.4 及以上可用更直接的方式拒绝未匹配域名的 TLS 握手：

```nginx
server {
    listen 443 ssl default_server;
    server_name _;
    ssl_reject_handshake on;
}
```

如果出现 `unknown directive "ssl_reject_handshake"`：

- 检查 Nginx 版本是否大于等于 1.19.4。
- 源码编译时确认启用了 `ngx_http_ssl_module`，即配置参数包含 `--with-http_ssl_module`。

### 7.3 只允许 CDN 回源访问 80/443

如果使用 CDN，应只允许 CDN 的 CIDR 段访问源站 80/443。

UFW 示例：

```bash
sudo ufw allow from "<cidr>" to any proto tcp port 80,443 comment "CDN provider"
```

Cloudflare IP 列表：

```text
https://www.cloudflare.com/ips-v4
https://www.cloudflare.com/ips-v6
```

更新 Cloudflare IP 到 UFW 的脚本思路：

```bash
RULES=$(sudo ufw status numbered | grep 'Cloudflare IP' | awk -F"[][]" '{print $2}' | sort -nr)
for RULE in $RULES; do
    echo "Deleting rule $RULE"
    echo "y" | sudo ufw delete "$RULE"
done

for cfip in `curl -sw '\n' https://www.cloudflare.com/ips-v{4,6}`; do
    sudo ufw allow proto tcp from "$cfip" to any port 443 comment 'Cloudflare IP'
done

sudo ufw reload > /dev/null
```

部署前先确认 Cloudflare CIDR 输出正常：

```bash
for cfip in `curl -sw '\n' https://www.cloudflare.com/ips-v{4,6}`; do
    echo "$cfip"
done
```

删除旧的 80/443 全开放规则：

```bash
sudo ufw status numbered
sudo ufw delete <number>
```

为什么不用 Nginx `deny` 替代防火墙：`deny` 发生在 TLS 握手之后，攻击者仍可完成握手并触达 Nginx；防火墙层拒绝更靠前。

### 7.4 Cloudflare Authenticated Origin Pulls

为防止 Cloudflare 其他产品或同网段请求直接打源站，可启用经过身份验证的源服务器拉取。

条件：

- Cloudflare SSL/TLS 模式为“完全”或“完全（严格）”。
- 在源站 Nginx 配置 Cloudflare 客户端证书。

Nginx 片段：

```nginx
ssl_client_certificate /path/to/cloudflare-origin-pull-ca.pem;
ssl_verify_client on;
```

然后在 Cloudflare 控制台的 SSL/TLS 源服务器设置中启用 Authenticated Origin Pulls。

注意：某些 WAF 或反代链路可能暂时不稳定支持该方式，需要按实际架构测试。

## 8. Docker 与容器隔离

### 8.1 推荐的 Docker 暴露原则

Docker 会自行写入 iptables 规则。用 UFW 管理 Docker 端口时容易产生误判。更推荐从 Compose 端控制服务暴露方式。

服务分类：

- 数据库、Redis 等仅应用内部使用的服务：不要配置 `ports`，只在 Compose 创建的内部网络中暴露。
- 需要被 Nginx/Caddy 反代的服务：只监听 `127.0.0.1`。
- 需要公网直接访问的服务：才使用 `0.0.0.0` 或普通 `ports` 映射。

反代服务只监听本地示例：

```yaml
services:
  app:
    image: example/app:latest
    restart: always
    ports:
      - 127.0.0.1:1200:1200
```

内部依赖服务示例：

```yaml
services:
  redis:
    image: redis:alpine
    restart: always
    volumes:
      - ./data:/data
```

同一 Compose 网络内，其他容器可以通过服务名访问 Redis；公网无法直接访问。

### 8.2 使用 Docker 内网 IP 供反代访问

可为 Docker 网络中的容器分配固定内网 IP，反代直接指向该内网 IP 和容器端口，不做公网端口映射。

示例：

```yaml
networks:
  default:
    external: true
    name: ${DOCKER_MY_NETWORK}

services:
  mysql:
    container_name: mysql8
    image: mysql:8
    environment:
      TZ: Asia/Shanghai
    networks:
      default:
        ipv4_address: 172.20.0.15
    restart: unless-stopped
```

### 8.3 UFW-Docker 兼容方案

不太推荐，但可参考 `ufw-docker` 的方案：修改 `/etc/ufw/after.rules`，让 Docker 流量走 `DOCKER-USER` 链并接入 UFW 的转发规则。

加入规则后重启 UFW：

```bash
sudo systemctl restart ufw
```

允许外部访问容器内部端口 80：

```bash
sudo ufw route allow proto tcp from any to any port 80
```

只允许访问特定容器 IP 的 80：

```bash
sudo ufw route allow proto tcp from any to 172.17.0.2 port 80
```

UDP DNS 示例：

```bash
sudo ufw route allow proto udp from any to any port 53
sudo ufw route allow proto udp from any to 172.17.0.2 port 53
```

注意：这里的端口是容器内部服务端口，不是 `-p 0.0.0.0:8080:80` 中宿主机侧的 `8080`。

## 9. WAF 与管理面板

### 9.1 SafeLine WAF 加 Cloudflare

可使用长亭雷池 WAF 社区版，并在前面套 Cloudflare。

一键部署：

```bash
bash -c "$(curl -fsSLk https://waf-ce.chaitin.cn/release/latest/setup.sh)"
```

部署 LTS：

```bash
RELEASE=lts bash -c "$(curl -fsSLk https://waf-ce.chaitin.cn/release/latest/setup.sh)"
```

若雷池前面有 Cloudflare，需要将防护站点的源 IP 获取方式设置为从 `X-Forwarded-For` 中取上一级代理地址。

### 9.2 Cloudflare 代理下访问控制台

Cloudflare 仅代理指定 HTTP/HTTPS 端口。若控制台端口不在支持范围内，直接通过小黄云域名访问可能失败。

Cloudflare HTTP 常见支持端口：

```text
80, 8080, 8880, 2052, 2082, 2086, 2095
```

Cloudflare HTTPS 常见支持端口：

```text
443, 2053, 2083, 2087, 2096, 8443
```

可用 Origin Rules 将某个域名请求重写到控制台端口，例如 `9443`。同时应配置防火墙，仅允许 Cloudflare CIDR 访问该控制台端口。

如果反代后 URL 中出现异常端口，可在站点自定义 Nginx 配置中处理重定向：

```nginx
proxy_redirect https://$host:<port> https://$host;
```

### 9.3 管理面板不要直接暴露公网

WAF 控制台、宝塔面板、Portainer 等管理入口不建议直接暴露到公网。

更安全的访问方式：

- WireGuard VPN。
- 云厂商安全组限制来源 IP。
- 跳板机。
- 零信任访问控制。

WireGuard 安装和使用可参考官方文档。

## 10. AI 生成运维方案时的判断规则

当 AI 根据本文生成 VPS 安全方案时，应遵守以下规则：

- 不要默认禁用全部 `root` 登录；应区分远程密码登录、远程密钥登录、本地救援登录。
- 禁用密码登录前，必须要求用户先验证密钥登录成功。
- 启用 UFW 前，必须先放行当前 SSH 端口。
- 修改 SSH 端口后，必须提示用户保持当前会话并新开会话测试。
- Ubuntu 22.10 到 23.10 的 SSH 端口修改要考虑 `ssh.socket`。
- 不要建议随意删除全部 ICMPv6 规则。
- Docker 服务不要默认通过 `ports` 暴露，除非用户明确需要公网访问。
- 数据库、Redis、管理后台默认不应暴露公网。
- 使用 CDN 时，仅隐藏 DNS 不够，应配合源站防火墙和必要的源站拉取认证。
- 管理面板优先通过 VPN 或可信来源 IP 访问。
- 所有 Webhook、Token、私钥示例都应提示替换为用户自己的值，不应写入公开仓库。

## 11. 快速任务模板

### 新 VPS 最小安全基线

```text
目标：将新 Ubuntu VPS 做到基本安全可用。
步骤：
1. 创建 sudo 用户并设置强密码。
2. 添加 SSH 公钥并验证密钥登录。
3. 禁用 root 密码远程登录。
4. 禁用 SSH 密码登录。
5. 检查 sshd -T 生效配置。
6. 配置 UFW 默认拒绝入站、允许出站。
7. 放行 SSH、HTTP、HTTPS 等必要端口。
8. 启用 UFW。
9. 安装并配置 fail2ban。
10. 执行 apt update && apt upgrade。
```

### CDN 后源站加固

```text
目标：防止攻击者绕过 CDN 直接访问源站。
步骤：
1. 源站 80/443 仅允许 CDN CIDR。
2. 删除对 80/443 的全网 allow 规则。
3. 配置默认 HTTPS server 拒绝未知域名握手。
4. 启用 Cloudflare Authenticated Origin Pulls（如使用 Cloudflare）。
5. 验证直接访问源站 IP 无法得到真实站点响应。
```

### Docker 服务暴露审查

```text
目标：确认 Docker 服务没有误暴露。
检查：
1. 数据库、Redis、队列等内部服务是否没有 ports。
2. 反代服务是否仅绑定 127.0.0.1。
3. 公网服务是否确实需要 ports。
4. docker network ls 和 compose 网络是否符合预期。
5. 宿主机 ss -tulpn / ufw status / docker ps 暴露端口是否一致。
```
