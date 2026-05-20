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

### Server B 内部 Claude marketplace 安全边界

internal Claude Code plugin marketplace（`prompts/0519-1/marketplace-bootstrap/`）的安全边界由 ADR-4（spec.md §5.2，LOCKED via WebFetch 实测）+ panel.uuhfn.cloud `@panel_private` + 独立 SSH 双通道支撑。整体定位 internal-only，**不镜像 anthropic/claude-code 或任何 proprietary upstream**。

#### 暴露面

| 面 | 允许 | 禁止 |
|----|------|------|
| `panel.uuhfn.cloud`（公网） | 仅 vpn-first allowlist（`@panel_private` matcher）；非 allowlist 来源 403 | 公网无差别访问 admin endpoint；公网爆破 X-Admin-Key |
| `files.uuhfn.cloud/git/bifrost-internal-plugins.git` | 公网只读 clone（fcgiwrap，HTTP smart protocol） | `git-receive-pack`（Caddy 已硬阻 403） |
| Server B `marketplace-render.service` 写入 `/var/lib/git-mirrors/...` | 仅 root；marketplace-render 通过 systemd unit 执行 | 任何用户态写入 bare 仓库 |
| `bifrost-admin` SSH 写通道 | forced-command 仅 5 verbs：`upload tag-create approve curate rerender` | 任意 SSH 命令；交互 shell；root 私钥复用 |
| `bifrost-readonly` SSH 读通道（PR-2 既有） | forced-command 白名单（marketplace:status, list-json, disk-report, logs:marketplace-render, logs:upstream-schema-check） | 写命令、其它服务的日志、状态文件 |

#### `@panel_private` 解释（PR-3 落地后生效）

panel.uuhfn.cloud 走 vpn-first allowlist 而不是公网。Caddy 在 `Caddyfile-a` 顶层定义 `@panel_private` matcher（`remote_ip` + VPN/私网段），匹配命中后才允许 reverse_proxy 到 bifrost-api；其它来源直接 403。这把"admin 上传 panel"的暴露面收回到管理网/VPN，**与 hardening-v2 PR-3 的 `vpn-first` profile 协同**。RK-4 因此被显式闭合（公网 token 爆破窗口归零）。

> DNS 上 `panel.uuhfn.cloud` 仍解析到 Server A 公网 IP（普通员工浏览器 → Server A 入口走 wg0 隧道），但 Caddy 在 vpn-first allowlist 失配时直接 403，不把请求转发到 bifrost-api，也不读 X-Admin-Key。

#### X-Admin-Key 轮换 SOP

bifrost-api 通过 `BIFROST_ADMIN_KEY` 环境变量配置，由 `require_admin` dependency 在所有 `/marketplace/*` 路由强制要求 `X-Admin-Key` header。轮换流程：

```bash
# 1. 生成新 key
NEW_KEY="$(openssl rand -hex 32)"

# 2. 写入 systemd drop-in 或 /etc/bifrost-api/env
sudo tee /etc/bifrost-api/env.d/admin-key.conf > /dev/null <<ENV
BIFROST_ADMIN_KEY=${NEW_KEY}
ENV
sudo chmod 0600 /etc/bifrost-api/env.d/admin-key.conf

# 3. 重启 bifrost-api（让新 key 生效，旧 key 立即失效）
sudo systemctl restart bifrost-api

# 4. 通知需要上传/curate 的管理员（带外 / 加密通道）；NewAPI Token 单独管理
```

频率建议每季度 + 人员变动 + 异常调用后立即。**严禁**把 X-Admin-Key 写入 git 仓库、CI 配置或 settings template。

#### ADR-4 LICENSE 引用

ADR-4 决策（spec.md §5.2，LOCKED via WebFetch 实测）：**DENY** 镜像 anthropic/claude-code。因此：

- `prompts/0519-1/marketplace-bootstrap/bifrost-internal-plugins/LICENSE` 显式声明 `ALL-RIGHTS-RESERVED`
- `bifrost-internal-plugins/NOTICE` 明示不镜像 upstream
- `marketplace.json.metadata.upstream_url = null`
- `marketplace.json.metadata.license_id = "ALL-RIGHTS-RESERVED"`

每个 plugin 子目录可以带自己的 LICENSE 文件；默认 policy 是 `ALL-RIGHTS-RESERVED`，除非明确覆盖。任何镜像 upstream 的尝试（PR-1b 路径）当前 deferred，触发条件由 `check-upstream-schema.sh` 监控。

#### `permissions.deny` 设计（PR-6 settings template）

`prompts/0519-1/team-config/.claude/settings.json.template` 默认下发的 `permissions.deny` 12 条硬阻：

- `Bash(curl http://github.com/*)` / `Bash(curl https://github.com/*)`
- `Bash(curl http://raw.githubusercontent.com/*)` / `Bash(curl https://raw.githubusercontent.com/*)`
- `Bash(wget http://github.com/*)` / `Bash(wget https://github.com/*)`
- `Bash(npm install *)`
- `Bash(pip install --index-url *)` / `Bash(pip install --extra-index-url *)`
- `WebFetch(domain:github.com)` / `WebFetch(domain:raw.githubusercontent.com)`
- `WebFetch(domain:registry.npmjs.org)`

这是 RK-2（恶意 plugin hook 提权）的最后一道防线：即便恶意 plugin 通过 admin upload 审核失误进入仓库，它的任何"从公网 GitHub 拉 payload"或"npm install"动作会被 Claude Code 在执行前 deny。**任何缩减 `deny` 都是 security review 范围的变更**，必须走 PR review + 多人 sign-off。

#### `bifrost-admin` SSH 通道

PR-5a 的设计：

- 独立 Linux user `bifrost-admin`（与 `bifrost-readonly` 完全分开）
- `~bifrost-admin/.ssh/authorized_keys` 的每一条 key 都走 `command="/usr/local/bin/bifrost-admin-router.sh"` + `no-port-forwarding,no-X11-forwarding,no-agent-forwarding,no-pty,restrict`
- `bifrost-admin-router.sh` 仅接受 5 verbs（`upload tag-create approve curate rerender`），其它输入 exit 2
- 所有动作 `printf '%s %s %s\n' "$(date -Iseconds)" "${VERB}" "${audit_id}" >> /var/log/marketplace/admin-audit.log`
- bifrost-api 经 `subprocess.run(['ssh', '-i', settings.admin_ssh_key, ...])` 调用，**不复用 readonly key**（M11 闭合）

读通道（PR-2 既有 `bifrost-readonly`）和写通道（PR-5a `bifrost-admin`）即使一方泄露，另一方权限不会被牵连——这是双通道隔离的安全前提。

#### Plugin hook 提权风险（RK-2 缓解）

Claude Code plugin 通过 `.claude-plugin/plugin.json` + `manifest.yaml` 声明 declared_hooks / declared_mcp_servers / declared_skills。RK-2（恶意 plugin hook 提权）通过三层缓解：

1. **panel curate**：admin upload 时人工审核 manifest.yaml + plugin 内容（panel.uuhfn.cloud admin SPA + audit log）
2. **`permissions.deny`**：即使 hook 通过审核，运行时 Claude Code 仍会 deny 公网 GitHub / npm 等高危动作
3. **audit log**：`/var/log/marketplace/admin-audit.log` 记录 upload / approve / curate / rerender 全链路，事后可追溯

#### upstream LICENSE 漂移监测（RK-1 + RK-5 缓解）

`scripts/check-upstream-schema.sh` 由 `upstream-schema-check.timer` 每日运行：

- 抓 `https://github.com/anthropics/claude-code/raw/main/LICENSE.md` 的 sha256
- 与 baseline（`/etc/bifrost-api/marketplace/upstream-license-baseline.sha256`）比对
- 不变：`LICENSE-OK <sha256> <ts>`，state.json `upstream_alert = false`
- 漂移：`UPSTREAM-CHANGED <old> -> <new> <ts>`，state.json `upstream_alert = true`，Vue admin panel 红色 badge

AC-12 验收命令（spec.md §11 + e2e rehearsal 自动执行）：

```bash
bash scripts/check-upstream-schema.sh 2>&1 | head -1 | \
    grep -E '^(LICENSE-OK|LICENSE-BASELINE-INIT|UPSTREAM-CHANGED) [0-9a-f]{64}'
jq -e '.upstream_alert == false' /var/lib/dist/plugins/state.json
```

当 alert 触发，agent manager 介入 SOP：

1. 人工对照新版 LICENSE / Commercial Terms，确认是否变为 OSS license
2. 如果是 OSS license（如 MIT/Apache-2.0），评估是否启动 PR-1b（mirror upstream）路径
3. 如果仍 proprietary 但条款收紧（如禁止内部 fork），通知法务 + 团队
4. **不要**自动更新 baseline；baseline 更新必须人工 commit + PR review

#### 审计日志查阅

```bash
# 读通道（PR-2 既有 — render / schema-check 日志）
curl -H "X-Admin-Key: ${ADMIN_KEY}" \
  "https://<server-a-domain>/manage/marketplace/logs?service=render&tail=200"

curl -H "X-Admin-Key: ${ADMIN_KEY}" \
  "https://<server-a-domain>/manage/marketplace/logs?service=schema-check&tail=200"

# 写通道（PR-5a — 仅 admin-audit.log；当前 PR-7 docs marker，
# bifrost-readonly-router.sh 的 logs:admin-audit verb 是 PR-5a 范围
# 但未在 readonly-router 中开放，PR-7 不补；当 admin-audit 可读时
# 通过 /marketplace/logs?service=admin-audit 出口）
```

bifrost-api 当前对 `service=admin-audit` 返回 422（spec.md §7.2 占位），等 PR-5a 在 `bifrost-readonly-router.sh` 增加 `logs:admin-audit` verb（独立后续 PR）后，会自动转为 200。

#### 风险登记簿映射

参见 spec.md §12 风险登记簿，本小节涉及：

- RK-1（Anthropic 升级 marketplace 协议）— 由 `check-upstream-schema.sh` + docs min Claude Code 版本缓解
- RK-2（恶意 plugin hook 提权）— 由 `permissions.deny` + panel curate + audit log 三层缓解
- RK-4（panel 公网 token 爆破，**已闭合**）— `@panel_private` vpn-first
- RK-5（LICENSE 合规误判）— ADR-4 LOCKED + check-upstream-schema.sh + 强制 LICENSE/NOTICE
- RK-8（admin/readonly 通道混淆）— 两 user + 两 forced-command + audit log
- RK-12（C6 自指 upstream 死锁，**已闭合**）— bifrost-internal-plugins 不进 git-mirror-sync 矩阵
- RK-14（state.json 并发写）— `mktemp` + `mv` 原子替换

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
