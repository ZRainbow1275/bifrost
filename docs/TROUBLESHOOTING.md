# Bifrost - 疑难排查指南 (v2.0)

## 快速诊断

运行自带的健康检查脚本，一键诊断核心组件，并覆盖公网管理面的关键合同：

```bash
cd /path/to/bifrost
./install.sh --health-check
sudo bash scripts/health-check.sh --verbose
```

当前健康检查会同时写出 `/var/log/bifrost/health.json`，重点包含：
- `bifrost_api`: 本地 `/health`、缺失管理密钥 `401`、错误管理密钥 `403`
- `caddy`: 反向代理/TLS 入口服务状态
- `public_manage`: `https://<DOMAIN>/manage/*` 的暴露面 profile、HTTP 状态、`/manage/register`、`/manage/docs` 与 `/manage/openapi.json` 前缀契约；`vpn-first` 下公网 `403` 表示管理面已被保护

### 深度诊断 (v2.0)

如需更详细的诊断，使用深度诊断模块：

```bash
bash scripts/diagnostics.sh full      # 系统 + 服务 + 网络 + DNS + 速度全链路诊断
bash scripts/diagnostics.sh gfw       # GFW 检测分析 (时序分析 + 丢包检测)
bash scripts/diagnostics.sh report    # 导出完整 JSON 诊断报告
```

说明：
- 默认报告目录是 `/var/log/bifrost`。
- 如果当前环境无法写入该目录，`diagnostics.sh` 会自动降级到 `/tmp/bifrost`，而不是直接失败。
- 在 Windows Git Bash 这类非目标运行壳层里，`ping -c` 可能不受支持；当前脚本会把相关 packet loss 项显式标记为 `SKIP`，避免误报为 `100% loss`。

### GitHub 下载失败 / 镜像切换

部署、升级和安全工具安装会优先直连 GitHub，失败后再尝试 `scripts/common.sh` 中定义的镜像前缀列表。

如果默认镜像在当前网络不可用，不要去改脚本里的硬编码 URL，直接在当前 shell 覆盖镜像集合后重试：

```bash
export BIFROST_GITHUB_MIRROR_PREFIXES="https://mirror-a.example,https://mirror-b.example"

sudo ./install.sh
# 或
sudo bash scripts/update.sh check
```

如需恢复默认行为，关闭当前 shell 或重新 `unset BIFROST_GITHUB_MIRROR_PREFIXES`。

---

## 1. 隧道连接问题

### 症状：API 调用超时 / 连接失败

**检查步骤：**

```bash
# 1. 检查 Xray 服务状态
systemctl status xray

# 2. 查看 Xray 日志
journalctl -u xray -n 50 --no-pager
# 或
tail -50 /var/log/xray/error.log

# 3. 测试隧道连通性（仅 Server A）
curl -x socks5h://127.0.0.1:10808 https://api.anthropic.com/v1/models -v

# 4. 测试 HTTP 代理（仅 Server A）
curl -x http://127.0.0.1:10809 https://api.anthropic.com/v1/models -v

# 5. 检查 Server B 是否可达
ping SERVER_B_IP
telnet SERVER_B_IP 443
```

**常见原因与解决：**

| 原因 | 解决方案 |
|------|---------|
| Server B IP 被封 | 更换 Server B IP 或使用 CDN |
| Reality 配置错误 | 检查 PublicKey/PrivateKey/UUID/SNI 是否一致 |
| GFW 封锁升级 | 更换 Dest/SNI（避免使用 google.com，改用 dl.google.com 或 www.microsoft.com） |
| 端口被云厂商封锁 | 检查安全组规则，确保 443 端口开放 |
| Xray 版本过低 | 升级 Xray：`bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install` |

### 症状：连接不稳定 / 频繁断开

```bash
# 1. 检查网络质量
mtr SERVER_B_IP

# 2. 检查 BBR 是否启用
sysctl net.ipv4.tcp_congestion_control
# 应输出: net.ipv4.tcp_congestion_control = bbr

# 3. 如果用 Hysteria 2，检查 UDP 是否被限制
# 某些网络环境限制 UDP，可能导致 Hysteria 2 不稳定
```

---

## 2. New API 问题

### 症状：New API 容器无法启动

```bash
# 1. 检查 Docker 状态
docker ps -a | grep new-api

# 2. 查看容器日志
docker logs new-api --tail 100

# 3. 检查端口占用
ss -tlnp | grep 3000

# 4. 重启容器
cd /opt/new-api
docker compose down
docker compose up -d

# 5. 检查磁盘空间
df -h /
```

#### PostgreSQL 密码或 TLS 连接错误

典型日志：

```text
failed SASL auth: FATAL: password authentication failed
SQLSTATE 28P01
tls error: server refused TLS connection
```

处理顺序：

```bash
cd /opt/new-api

# 1. 先验证 compose，不要直接 up
docker compose config --quiet

# 2. 查看脚本生成并复用的环境文件
grep -E 'NEW_API_DB_DRIVER|NEW_API_SQL_DSN|NEW_API_POSTGRES_USER|NEW_API_POSTGRES_DB' .env

# 3. 确认 PostgreSQL 内部连接显式禁用 TLS
grep -q 'sslmode=disable' .env && echo ok

# 4. 如果 postgres-data 已存在，不要随手改 .env 里的密码
ls -ld postgres-data
docker compose logs --tail 120 new-api postgres
```

关键点：PostgreSQL volume 初始化后，数据库内部密码不会因为你修改 `docker-compose.yml` 或 `.env` 自动同步。正确做法是恢复原来的 `/opt/new-api/.env`，或在重新部署前设置 `BIFROST_NEW_API_POSTGRES_PASSWORD` 为旧数据库密码。只有在确认已备份并接受清空数据时，才手动停止 compose 并删除 `postgres-data/` 后重建。

#### 3000 端口暴露检查

New API 不应该直接暴露到公网，公网入口只能走 Caddy：

```bash
docker ps --filter 'name=^/new-api$' --format '{{.Ports}}'
# 正确示例: 127.0.0.1:3000->3000/tcp
# 错误示例: 0.0.0.0:3000->3000/tcp
```

如果看到 `0.0.0.0:3000` 或 `:::3000`，立即修改 `/opt/new-api/docker-compose.yml` 为：

```yaml
ports:
  - "127.0.0.1:3000:3000"
```

### 症状：New API 无法连接上游 AI API

```bash
# 1. 确认 Mihomo 路由引擎运行中
curl -x http://127.0.0.1:7890 https://api.openai.com/v1/models

# 2. 确认 Xray 隧道运行中（Mihomo 的上游）
curl -x socks5h://127.0.0.1:10808 https://api.openai.com/v1/models

# 3. 检查 Docker 容器的代理配置
docker inspect new-api | grep -A5 -i proxy

# 4. 确认环境变量正确
docker exec new-api env | grep -i proxy
# 应看到:
#   HTTP_PROXY=http://host.docker.internal:7890
#   HTTPS_PROXY=http://host.docker.internal:7890

# 5. 容器内测试连接
docker exec new-api curl -x http://host.docker.internal:7890 https://api.anthropic.com/v1/models
```

**关键提示：** Docker 容器通过 `host.docker.internal` 访问宿主机的 Mihomo 路由引擎（端口 7890）。Mihomo 负责路由决策，并将代理流量转发至 Xray SOCKS5（127.0.0.1:10808）。如果此网络不通，检查 docker-compose.yml 中的 `extra_hosts` 配置。

### 症状：用户报告 "模型不可用"

```bash
# 1. 登录 New API 管理面板
# 2. 检查「渠道」页面：
#    - 渠道是否启用
#    - 上游 API Key 是否有效
#    - 余额是否充足
# 3. 检查「日志」页面的错误信息
# 4. 在「操练场」测试模型调用
```

---

## 3. Caddy / HTTPS 问题

### 症状：网站无法访问 / HTTPS 证书错误

```bash
# 1. 检查 Caddy 状态
systemctl status caddy

# 2. 查看 Caddy 日志
journalctl -u caddy -n 50 --no-pager

# 3. 检查证书
caddy list-certificates
certbot certificates

# 4. 验证 Caddyfile 语法
caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile

# 5. 检查 80/443 端口
ss -tlnp | grep -E ':80|:443'

# 6. 确认域名解析
dig your-domain.com
nslookup your-domain.com

# 7. IP HTTPS 模式：检查短生命周期 IP 证书续期 timer
systemctl status bifrost-certbot-renew.timer
systemctl list-timers | grep -E 'bifrost-certbot-renew|certbot'
certbot renew --dry-run --cert-name <SERVER_A_PUBLIC_IPV4>
```

**常见原因：**
- 域名未解析到服务器 IP
- 80 端口被占用（证书自动获取需要 80 端口）
- 国内服务器域名未备案
- IP HTTPS 模式未开放公网 `80/tcp`，Let's Encrypt HTTP-01 challenge 或后续续期无法到达 Server A
- Certbot 版本低于 5.4，缺少 `--ip-address` 或 IP webroot 支持
- Caddyfile 中 IP 模式没有显式加载 `/etc/letsencrypt/live/<IP>/fullchain.pem` 与 `privkey.pem`
- Cloudflare Origin CA 模式下证书或私钥路径不存在、文件为空，或 Cloudflare SSL/TLS 未设置为 `Full (strict)`

### 症状：Cloudflare Origin CA 模式下 Caddy 启动失败

典型日志：

```text
loading certificates: open /etc/caddy/certs/api.example.com-origin.pem: no such file or directory
```

处理：

```bash
# 1. 确认证书和私钥文件存在且非空
sudo test -s /etc/caddy/certs/api.example.com-origin.pem
sudo test -s /etc/caddy/certs/api.example.com-origin.key

# 2. 确认 Caddy 能读取
sudo chmod 600 /etc/caddy/certs/api.example.com-origin.*
sudo chown root:caddy /etc/caddy/certs/api.example.com-origin.* 2>/dev/null || true

# 3. 用与部署脚本一致的命令验证
sudo caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile

# 4. 重启并看日志
sudo systemctl restart caddy
sudo journalctl -u caddy -n 80 --no-pager
```

Cloudflare 面板同时确认：

- DNS 记录为 Proxied。
- SSL/TLS Overview 为 `Full (strict)`。
- Origin Server 证书覆盖当前主机名，例如 `api.example.com` 或 `*.example.com`。
- 对 API 和管理路径配置 Bypass cache，不要缓存 `/v1/*`、`/api/*`、`/dashboard*`、`/login`、`/static/*`。

### 症状：IP HTTPS 证书 6 天内过期或浏览器提示证书无效

```bash
# 1. 查看当前证书和到期时间
certbot certificates --cert-name <SERVER_A_PUBLIC_IPV4>
openssl x509 -in /etc/letsencrypt/live/<SERVER_A_PUBLIC_IPV4>/fullchain.pem -noout -issuer -dates -ext subjectAltName

# 2. 检查 Bifrost 续期 timer
systemctl status bifrost-certbot-renew.timer
journalctl -u bifrost-certbot-renew.service -n 80 --no-pager

# 3. 手动触发一次续期并重载 Caddy
certbot renew --cert-name <SERVER_A_PUBLIC_IPV4>
systemctl reload caddy
```

IP 证书是短生命周期证书，有效期约 160 小时。不要按传统 90 天证书节奏维护；如果 `bifrost-certbot-renew.timer` 没有正常运行，必须先修复 timer、`80/tcp` 可达性和 Certbot 版本。

---

## 4. 3x-ui 面板问题

### 症状：面板无法访问

```bash
# 1. 检查 x-ui 服务
systemctl status x-ui

# 2. 查看日志
journalctl -u x-ui -n 50

# 3. 确认面板端口（默认 2053，可能已改）
ss -tlnp | grep x-ui

# 4. 检查防火墙
ufw status  # 或 firewall-cmd --list-all

# 5. 重启面板
x-ui restart

# 6. 重置面板设置
x-ui reset
```

### 忘记 3x-ui 面板密码

```bash
# 重置用户名和密码
x-ui reset
# 将重置为默认: admin/admin
# 登录后请立即修改密码
```

---

## 5. 安全相关问题

### 症状：SSH 无法登录

```bash
# ⚠️ 切勿关闭当前 SSH 连接！先在新终端测试

# 1. 检查 SSH 端口
ss -tlnp | grep sshd

# 2. 检查 fail2ban 是否封禁了你的 IP
fail2ban-client status sshd
# 如果被封禁，解封：
fail2ban-client set sshd unbanip YOUR_IP

# 3. 检查防火墙规则
ufw status  # 或 firewall-cmd --list-all

# 4. 检查 SSH 配置
sshd -T | grep -E 'port|passwordauthentication|permitrootlogin'

# 5. 如果配置损坏，恢复备份（备份文件名含时间戳）
# 查看可用备份: ls -lt /etc/ssh/sshd_config.bak.*
cp "$(ls -t /etc/ssh/sshd_config.bak.* 2>/dev/null | head -1)" /etc/ssh/sshd_config
systemctl restart sshd
```

### 症状：服务器被云厂商警告

**立即操作：**
1. 检查是否有异常流量（非 AI API 域名的流量）
2. 确认白名单配置正确
3. 确认伪装网站正常显示
4. 暂停服务，排查后再恢复

```bash
# 检查 Xray 出站流量日志
tail -100 /var/log/xray/access.log

# 检查是否有白名单外的流量
grep -v -E 'anthropic|openai|google|deepseek|mistral' /var/log/xray/access.log
```

---

## 6. 性能问题

### 症状：API 响应慢

```bash
# 1. 测试基准延迟
time curl -x socks5h://127.0.0.1:10808 https://api.anthropic.com/v1/models -o /dev/null -s

# 2. 检查服务器资源
htop  # 或 top
free -m
df -h

# 3. 检查 Netdata 监控面板 (仅限本地访问)
# http://127.0.0.1:19999
# 远程访问: ssh -L 19999:127.0.0.1:19999 root@SERVER_IP

# 4. 检查 BBR 状态
sysctl net.ipv4.tcp_congestion_control

# 5. 检查带宽使用
# Netdata → Network 面板

# 6. 优化建议
# - 升级 Server B 到更近的节点（日本/香港）
# - 增加带宽
# - 如果用 TCP，考虑切换到 Hysteria 2（基于 QUIC）
```

---

## 7. VPN 连接问题

### 症状：VPN 无法连接

```bash
# 1. 检查 WireGuard 接口状态
sudo wg show wg0

# 2. 检查 WireGuard 服务
sudo systemctl status wg-quick@wg0

# 3. 检查 WireGuard UDP 端口是否开放
WG_PORT=$(sudo awk -F= '/^BIFROST_WG_PORT=/ {print $2}' /etc/bifrost.env 2>/dev/null || true)
sudo ss -ulnp | grep "${WG_PORT:-51820}"

# 4. 检查防火墙是否放行
sudo iptables -L INPUT -n | grep "${WG_PORT:-51820}"

# 5. 检查 Firezone 状态 (如使用 Firezone)
docker ps | grep firezone

# 6. 查看系统日志
sudo journalctl -u wg-quick@wg0 --no-pager -n 50
sudo dmesg | grep wireguard
```

**常见原因与解决：**

| 原因 | 解决方案 |
|------|---------|
| WireGuard UDP 端口被防火墙/安全组拦截 | 在云厂商安全组和本机防火墙同时放行 `/etc/bifrost.env` 中的 `BIFROST_WG_PORT`（旧安装可能为 `51820`） |
| 客户端配置错误 | 检查 Endpoint、PublicKey、AllowedIPs 是否正确 |
| 网络环境限制 UDP | 部分企业/酒店网络封锁非标准 UDP，换网络测试 |
| Firezone Docker 容器崩溃 | `docker compose -f /opt/firezone/docker-compose.yml restart` |
| Headscale 服务异常 | `systemctl restart headscale` |

### 症状：VPN 已连接但无法访问内部服务

```bash
# 1. 确认获取到 VPN IP
ip addr show wg0

# 2. 检查路由
ip route get 172.16.0.1

# 3. 检查 iptables VPN 规则
sudo iptables -L VPN_INPUT -n -v
sudo iptables -L VPN_FORWARD -n -v

# 4. 重新应用防火墙规则
sudo bash scripts/vpn.sh menu
# 选择 "Reconfigure firewall"
```

---

## 8. Mihomo 路由问题

### 症状：Mihomo 服务无法启动

```bash
# 1. 检查 Mihomo 状态
systemctl status mihomo

# 2. 查看日志
journalctl -u mihomo -n 50 --no-pager

# 3. 验证配置文件语法
/usr/local/bin/mihomo -t -d /etc/mihomo

# 4. 检查端口占用 (Mihomo 默认 7890)
ss -tlnp | grep 7890

# 5. 检查 GeoIP/GeoSite 数据文件
ls -la /etc/mihomo/GeoIP.dat /etc/mihomo/GeoSite.dat
# 如果缺失:
bash scripts/update.sh geoip
```

**常见原因与解决：**

| 原因 | 解决方案 |
|------|---------|
| 配置文件 YAML 语法错误 | `mihomo -t -d /etc/mihomo` 查看具体错误 |
| 端口 7890 被占用 | `ss -tlnp \| grep 7890` 找出冲突进程 |
| GeoIP/GeoSite 数据缺失 | `bash scripts/update.sh geoip` |
| Xray SOCKS5 上游不通 | 先检查 Xray 状态：`systemctl status xray` |

### 症状：AI API 通过 Mihomo 无法访问

```bash
# 1. 测试 Mihomo 代理连通性
curl -x http://127.0.0.1:7890 https://api.anthropic.com/v1/models -v

# 2. 测试 Xray 上游 (Mihomo 的后端)
curl -x socks5h://127.0.0.1:10808 https://api.anthropic.com/v1/models -v

# 3. 检查 Mihomo 规则匹配
journalctl -u mihomo -n 100 --no-pager | grep anthropic

# 4. 检查 Docker 容器代理配置
docker exec new-api env | grep -i proxy
# 应看到: HTTP_PROXY=http://host.docker.internal:7890
```

---

## 9. DPI 防护 / Dest 轮换问题

### 症状：Reality dest 验证失败

```bash
# 1. 手动测试目标站 TLS 1.3 + H2 支持
echo | openssl s_client -connect dl.google.com:443 -tls1_3 -alpn h2 2>/dev/null | grep 'Protocol\|ALPN'

# 2. 检查 dest-pool 文件
cat /opt/bifrost/dest-pool.txt

# 3. 手动轮换 dest
bash /opt/bifrost/rotate-dest.sh
```

### 症状：Dest 自动轮换没有执行

```bash
# 1. 检查 cron 任务
crontab -l | grep rotate

# 2. 检查轮换日志
tail -50 /var/log/bifrost-rotate.log

# 3. 手动执行轮换测试
bash /opt/bifrost/rotate-dest.sh
```

### 症状：怀疑被 GFW 识别

```bash
# 1. 运行 GFW 检测诊断
bash scripts/diagnostics.sh gfw

# 2. 更换 dest + SNI
bash scripts/anti-dpi.sh
# 选择重新配置 dest

# 3. 如果 Server B IP 已被封，紧急 IP 轮换
bash scripts/backup.sh rotate-ip <新ServerB-IP>
```

---

## 10. Keepalive / Watchdog 问题

### 症状：连接频繁断开（NAT 超时）

```bash
# 1. 检查 TCP keepalive 内核参数
sysctl net.ipv4.tcp_keepalive_time
sysctl net.ipv4.tcp_keepalive_intvl
sysctl net.ipv4.tcp_keepalive_probes
# 推荐值: time=30, intvl=10, probes=3

# 2. 检查 keepalive sysctl 配置
cat /etc/sysctl.d/99-keepalive.conf

# 3. 重新部署 keepalive
bash scripts/keepalive.sh
```

### 症状：Watchdog 未自动恢复崩溃的服务

```bash
# 1. 检查 Watchdog 状态
systemctl status ai-gw-watchdog

# 2. 查看 Watchdog 日志
journalctl -u ai-gw-watchdog -n 100 --no-pager

# 3. 检查心跳 timer 状态
systemctl status ai-gw-heartbeat.timer

# 4. 重启 Watchdog
systemctl restart ai-gw-watchdog
```

---

## 11. 多节点 / 故障转移问题

### 症状：某个 Server B 节点不可用

```bash
# 1. 测试所有节点
bash scripts/multi-server.sh test

# 2. 列出节点状态
bash scripts/multi-server.sh list

# 3. 移除故障节点
bash scripts/multi-server.sh remove <节点名称>

# 4. 添加替代节点
bash scripts/multi-server.sh add
```

### 症状：Mihomo proxy-group 未自动切换

```bash
# 1. 检查 Mihomo 日志
journalctl -u mihomo -n 100 --no-pager | grep -E 'proxy-group|fallback|url-test'

# 2. 检查 proxy-group 配置
cat /etc/mihomo/config.yaml | grep -A 20 'proxy-groups:'

# 3. 重启 Mihomo 触发重新健康检查
systemctl restart mihomo
```

---

## 12. 日志位置速查

| 组件 | 日志位置 |
|------|---------|
| 安装日志 | `/var/log/bifrost/bifrost.log` |
| Xray | `/var/log/xray/access.log`, `/var/log/xray/error.log` |
| Mihomo | `journalctl -u mihomo`, `/var/log/mihomo/` |
| Caddy | `/var/log/caddy/access.log` |
| New API | `docker logs new-api` |
| 3x-ui | `journalctl -u x-ui` |
| VPN (WireGuard) | `journalctl -u wg-quick@wg0`, `dmesg \| grep wireguard` |
| Firezone | `docker logs firezone` |
| Headscale | `journalctl -u headscale` |
| fail2ban | `/var/log/fail2ban.log` |
| SSH | `/var/log/auth.log` (Debian) / `/var/log/secure` (CentOS) |
| 健康检查 | `/var/log/bifrost/health.json` |
| 告警 | `/var/log/bifrost/alerts.log` |
| Dest 轮换 | `/var/log/bifrost-rotate.log` |
| Watchdog | `journalctl -u ai-gw-watchdog` |
| 心跳探测 | `journalctl -u ai-gw-heartbeat` |
| 诊断报告 | `bash scripts/diagnostics.sh report` (输出 JSON) |
| Netdata | `journalctl -u netdata` |
| Lynis 报告 | `/var/log/lynis-report.txt` |

---

## 13. 紧急恢复

### 完全重置 Xray

```bash
systemctl stop xray
# 恢复配置备份（备份文件名含时间戳，如 config.json.bak.1711234567）
# 查看可用备份:
ls -lt /usr/local/etc/xray/config.json.bak.*
# 使用最新的备份恢复:
cp "$(ls -t /usr/local/etc/xray/config.json.bak.* 2>/dev/null | head -1)" /usr/local/etc/xray/config.json
systemctl start xray
```

### 完全重置 New API

```bash
cd /opt/new-api
docker compose down
# 如需清除数据:
# rm -rf data/ redis-data/
docker compose up -d
```

### 完全重置 Mihomo

```bash
systemctl stop mihomo
# 重新部署 (会重新生成配置)
bash scripts/mihomo.sh deploy
```

### 完全重置 VPN

```bash
# Firezone
docker compose -f /opt/firezone/docker-compose.yml down
docker compose -f /opt/firezone/docker-compose.yml up -d

# Headscale
systemctl restart headscale

# WireGuard
systemctl restart wg-quick@wg0
```

### 紧急 IP 轮换 (Server B IP 被封)

```bash
# 自动更新 Xray + Mihomo 配置中的 Server B IP
bash scripts/backup.sh rotate-ip <新IP>
```

### 从加密备份恢复

```bash
# 列出可用备份
bash scripts/backup.sh restore

# 按提示选择备份文件并恢复
```

### 恢复防火墙

```bash
# Ubuntu/Debian
ufw reset
ufw default deny incoming
ufw default allow outgoing
ufw allow ssh
ufw allow 443/tcp
ufw allow 80/tcp
ufw --force enable

# CentOS
firewall-cmd --complete-reload
```

### 完全卸载

```bash
cd /path/to/bifrost
./install.sh --uninstall
```

---

## 14. 获取帮助

- 查看文档：`docs/` 目录
- 运行健康检查：`./install.sh --health-check` 或 `bash scripts/health-check.sh --verbose`
- 运行深度诊断：`bash scripts/diagnostics.sh full`
- 查看连接信息：`cat /root/ai-gateway-connection.txt`
- 查看 VPN 状态：`bash scripts/vpn.sh status`
- New API 文档：https://doc.newapi.pro
- 3x-ui Wiki：https://github.com/MHSanaei/3x-ui/wiki
- Xray 文档：https://xtls.github.io
- Mihomo Wiki：https://wiki.metacubex.one
- WireGuard 文档：https://www.wireguard.com/quickstart/
