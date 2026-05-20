# Bifrost - 安全说明

## 安全架构

```
用户终端 ←──TLS 1.3──→ Server A (Caddy) ←──VLESS+Reality──→ Server B ←──TLS──→ AI API
         全程加密           防火墙+fail2ban          全程加密          HTTPS
```

所有数据传输均使用加密通道，无明文暴露。

---

## 已实施的安全措施

### 1. 网络安全

| 措施 | 说明 |
|------|------|
| VLESS+Reality 隧道 | 流量伪装为正常 HTTPS，DPI 不可区分 |
| TLS 1.2/1.3 | Caddy 配置 TLS 1.2 及 TLS 1.3，兼顾兼容性与安全性 |
| 防火墙 | 默认拒绝所有入站，仅开放必要端口 |
| 域名白名单 | Xray 路由规则限制出站域名 |
| 流媒体封锁 | 明确拒绝 Netflix/YouTube 等域名 |

### 2. 系统安全

| 措施 | 说明 |
|------|------|
| SSH 加固 | 禁密码登录、禁 root 直连、自定义端口 |
| fail2ban | 暴力破解自动封禁（SSH: 3次/24h） |
| 内核加固 | SYN cookies、ASLR、禁 ICMP 重定向 |
| BBR | 拥塞控制优化 + SYN flood 防护 |
| 自动更新 | 安全补丁自动安装 |
| rkhunter | 每周 rootkit 扫描 |
| Lynis | 综合安全审计，目标 hardening index ≥ 65 |

### 3. 应用安全

| 措施 | 说明 |
|------|------|
| API Key 隔离 | 用户使用内部 Key，不接触上游 API Key |
| 配额管理 | 每用户独立配额，防止滥用 |
| 审计日志 | New API 记录所有 API 调用 |
| 容器隔离 | New API 运行在 Docker 中 |

---

## 合规提醒

### 法律风险

本工具涉及跨境网络服务，使用前请了解以下法律法规：

1. **《计算机信息网络国际联网管理暂行规定》第六条**：使用国际联网须经国际出入口信道提供单位。
2. **《网络安全法》第二十七条**：不得提供专门用于从事侵入网络等违法犯罪活动的工具。
3. **工信部 2017 年通知**：未经批准不得自行建立或租用国际专线。

### 风险缓解建议

1. **企业内部使用**：仅限公司员工，不对外提供服务
2. **白名单限制**：仅允许 AI API 域名，拒绝一般浏览
3. **合理流量模式**：避免 24/7 高带宽，保持正常业务流量模式
4. **伪装合规**：Server A 展示正常企业网站
5. **审计记录**：保留操作日志，证明合法使用场景
6. **不收费**：不以此服务收取费用（避免非法经营风险）

### 数据出境

如果处理敏感数据（如律所客户文件），请注意：
- API 调用内容会通过隧道传输到海外 AI 服务商
- 这可能触发《数据出境安全评估办法》的相关要求
- 建议对传输内容进行脱敏处理
- 咨询法律顾问了解具体合规要求

---

## 安全最佳实践

### 暴露面 Profile

Bifrost 支持三种暴露面 profile，并默认采用 `vpn-first`：

| Profile | 适用场景 | 安全要求 |
|---------|----------|----------|
| `vpn-first` | 生产默认 | 管理面只允许 VPN、私网或来源白名单访问；公网仅保留业务 API 与伪装站 |
| `public-managed` | 兼容需要公网管理入口的部署 | 必须配合强认证、WAF/来源白名单、限速、审计日志和云防火墙 |
| `lab` | 临时测试 | 可放宽限制，但不得用于生产 |

生产部署应验证以下暴露面：

1. `/v1/*` 可以作为 OpenAI-compatible API 公网入口。
2. `/dashboard`、`/login`、New API 前端静态资源（如 `/static/*`、`/logo.png`）以及 `/manage/*` 在 `vpn-first` 下必须从公网返回拒绝访问；白名单/VPN 来源访问管理 UI 时，这些静态资源必须同样反代到 New API，避免入口页面可达但 JS/CSS 不可用。
3. Server B 的 3x-ui 直接端口默认不得开放；`/xui-panel/` 在 `vpn-first` 下必须受 VPN/私网/来源白名单保护。
4. `New API` 镜像应使用固定版本或 digest；`latest` 只能在 `lab` 或显式 `BIFROST_ALLOW_UNPINNED=1` 时临时使用。

### Server B 私有分发栈安全边界

分发栈启用后，Server B 同时承载 Verdaccio、NewAPI、PostgreSQL、Redis、git mirror、静态 files 和 restic 备份任务。它的安全边界必须按“公网最小入口 + wg0 私网服务 + 专用低权只读通道”执行。

| 面 | 允许 | 禁止 |
|----|------|------|
| Server B 公网入站 | `22/tcp` 双通道维护入口、`51820/udp` WireGuard、既有 Xray Reality 端口 | `3000/4873/8081/8082` 从公网直接访问 |
| Server B wg0 入站 | A 和白名单 peer 访问 `3000/4873/8081/8082` | 团队成员绕过 A 直连 B 的服务端口 |
| Docker 端口 | 绑定 `10.8.0.2:<port>`，并用 `DOCKER-USER` drop 公网 eth0 | `0.0.0.0:<port>` 或仅依赖 nftables 主链 |
| bifrost-api 日志读取 | `bifrost-readonly` 专用用户 + forced-command 白名单 | root SSH 私钥、任意命令 SSH、交互 shell |
| Verdaccio bootstrap | 密码只 stdout 一次，并保存 `/root/.verdaccio-bootstrap-pwd.txt` 0400 | 写入 deploy state、日志、bifrost-api 响应 |
| Git mirror | Caddy 拒绝 `git-receive-pack`，只允许 clone/fetch | 允许 push 到镜像源 |

生产变更后必须运行：

```bash
bash scripts/diagnostics.sh --check distribution
iptables -S DOCKER-USER | grep -E '3000|4873|8081|8082'
nft list table inet filter
```

### 密钥与密码轮换

| 对象 | 频率 | 操作 |
|------|------|------|
| WireGuard A/B key | 90 天或泄露后立即 | 先把新公钥加入对端 peer，再替换本机私钥，最后 `wg-quick down wg0 && wg-quick up wg0` 验证 handshake |
| bifrost-readonly SSH key | 90 天或人员变更 | `ssh-keygen -t ed25519 -f /etc/bifrost-api/ssh/bifrost-readonly.ed25519 -N ""`，把新公钥写入 B 的 forced-command `authorized_keys`，删除旧公钥 |
| Verdaccio bootstrap 密码 | 首次分发后、人员变更、泄露后 | `bash scripts/server-b.sh --rotate-bootstrap-pwd`；新密码只发给需要发布私有包的管理员 |
| NewAPI 管理员密码/token | 每季度、成员离职、异常调用后 | 在新 NewAPI 管理面轮换；成员 token 必须逐人独立，不共享 |
| restic password | 年度或备份仓库泄露后 | 新建仓库或按 restic 官方流程迁移；旧仓库保留到恢复验证完成 |

WG 轮换时不要同时替换 A/B 两侧私钥。先利用现有隧道把新 peer 配置写入对端，确认新 handshake 小于 10 秒后再移除旧 peer。

### 备份与恢复边界

Server B 数据源包括：

- `/var/lib/verdaccio`
- `/var/lib/new-api-pg`
- `/var/lib/new-api-redis`
- `/var/lib/git-mirrors`
- `/var/lib/dist`

`restic-to-a.timer` 负责把这些目录备份到 Server A。真实生产验收不能只看 timer active，必须执行：

```bash
systemctl status restic-to-a.timer
systemctl start restic-to-a.service
restic snapshots
```

恢复演练先恢复到临时目录，比对文件和 PostgreSQL 数据目录完整性后，再进入维护窗口替换生产目录。不要在未验证快照可用前退订旧 Windows VPS 或删除 legacy 数据。

### NewAPI 绿启与账号重建

`BIFROST_SERVER_A_NEWAPI_MODE=distribution` 下，Server A 不再默认安装本地 NewAPI；NewAPI 在 B 上绿启。安全后果是旧 token 不迁移，团队成员必须重建：

1. 管理员初始化 B 上 NewAPI，生成新管理员密码。
2. 每个成员创建独立账号/token/配额。
3. 旧 Windows VPS 或 Server A legacy NewAPI 设置只读并保留最终快照 30 天。
4. 旧 token 在切流完成后集中作废，避免双写和权限漂移。

### Windows VPS 退役门禁

退订旧 Windows VPS 前必须满足：

- `npm.uuhfn.cloud`、`files.uuhfn.cloud`、`api.uuhfn.cloud` 已连续 7 天走 Server A → wg0 → Server B。
- `restic snapshots` 至少有 7 条 Server B 快照。
- 已导出 Windows VPS final snapshot，并能在离线环境列出 Verdaccio storage、Caddy 配置、git mirror tarball。
- 团队成员 NewAPI 账号重建完成，旧 token 作废。
- 已记录退役日期、快照位置、30 天清理日期。

### 定期操作清单

| 频率 | 操作 | 命令 |
|------|------|------|
| 每日 | 查看健康检查报告 | `cat /var/log/bifrost/health.json` |
| 每周 | 查看 fail2ban 封禁日志 | `fail2ban-client status sshd` |
| 每周 | 检查 rkhunter 扫描报告 | `cat /var/log/rkhunter.log` |
| 每月 | 运行 Lynis 安全审计 | `lynis audit system --quick` |
| 每月 | 更新所有组件 | 见 USAGE.md 更新组件部分 |
| 每月 | 轮换管理面板密码 | New API/3x-ui 面板设置 |
| 每季度 | 审计 API Key 使用情况 | New API 面板 → 日志 |
| 每季度 | 检查域名 SSL 证书有效期 | `caddy list-certificates` |
| 每日 | IP HTTPS 模式检查短生命周期证书续期 | `systemctl is-active bifrost-certbot-renew.timer && certbot certificates --cert-name <SERVER_A_PUBLIC_IPV4>` |
| 每日 | Server B 分发栈健康检查 | `bash scripts/diagnostics.sh --check distribution` |
| 每日 | Server B restic 快照检查 | `restic snapshots` |
| 每季度 | bifrost-readonly SSH key 轮换 | 见上方“密钥与密码轮换” |

### API Key 管理

1. 为每个用户创建独立的 Key
2. 设置合理的配额和到期时间
3. 离职员工立即禁用其 Key
4. 不要将上游 API Key 分发给用户
5. 定期审计 Key 使用情况

### 密码策略

- 所有面板密码至少 16 字符
- 使用随机生成的密码
- 不同服务使用不同密码
- 使用密码管理器存储

---

## 应急响应

### 如果发现异常

1. **立即检查日志**：`tail -100 /var/log/xray/access.log`
2. **检查是否有非白名单流量**
3. **如有必要，暂停 Xray 服务**：`systemctl stop xray`
4. **检查 fail2ban 封禁列表**：`fail2ban-client status`
5. **联系管理员处理**

### 如果收到云厂商警告

1. **立即暂停服务**
2. **排查异常流量来源**
3. **强化白名单规则**
4. **确认伪装网站正常**
5. **回复云厂商说明使用场景**

### 如果 IP 被封

1. **Server B**：更换 IP 或使用 CDN
2. **更新 Server A 的连接配置**
3. **考虑使用多节点备份**
