# Bifrost - 使用说明 (v2.0)

## 部署概述

Bifrost v2.0 采用双服务器 + VPN 网关架构，推荐按以下顺序部署：

```
Step 0: (可选) DD 系统重装 — 云环境就绪检查与全新部署前置准备
         ↓
Step 1: 部署 Server B (海外服务器) — Xray 服务端 + DPI 防护
         ↓ 获取连接信息
Step 2: 部署 Server A (国内服务器) — Xray 客户端 + New API + Caddy
         ↓
Step 2a: 部署企业 VPN (Server A) — WireGuard (Firezone/Headscale) 作为第一道门
         ↓
Step 2b: 部署 Mihomo 智能路由 (Server A) — 规则分流 (AI→代理, CN→直连)
         ↓
Step 2c: 部署增强模块 (Server A) — 连接保活 + 网络分流 + 备份
         ↓
Step 3: 创建 VPN 用户 — 生成 VPN 配置 + API Token + 入职指南
         ↓
Step 4: 员工入职 — 安装 WireGuard → 连 VPN → 配置 AI 工具
```

---

## 准备工作

### 服务器要求

| 项目 | Server A (国内) | Server B (海外) |
|------|----------------|----------------|
| 供应商 | 腾讯云/阿里云/华为云/京东云 | 推荐日本/香港/新加坡 VPS |
| 最低配置 | 2C4G, 5M 带宽 | 2C2G |
| 系统 | Ubuntu 22.04+, Debian 12+, CentOS 9+ | Ubuntu 22.04+, Debian 12+, CentOS 9+ |
| 端口 | 80, 443 | 443 |
| 域名 | 推荐（需 ICP 备案） | 可选 |

### 网络要求
- Server A 能访问 Server B 的 443 端口
- Server A 的 80/443 端口对用户开放
- Server A 的 WireGuard UDP 端口对 VPN 客户端开放（部署 VPN 时需要；当前值写入 `/etc/bifrost.env` 的 `BIFROST_WG_PORT`，旧安装可能为 `51820`）
- 两台服务器最好是全新安装的系统（推荐；如需 DD 重装，仅在首次部署前且完成备份/云依赖审查后使用）

---

## Step 0: (可选) DD 系统重装

如果你的服务器是从云厂商购买的（腾讯云、阿里云、AWS、Vultr 等），在决定是否执行 DD 前，先完成云环境一致性/备份/确认检查：`cloud metadata`、`cloud-init`、SSH key 注入方式、安全组/防火墙、控制台监控告警、审计/安全代理、自动化恢复链路，以及任何云厂商合规依赖。DD 会擦除整盘，只适合**全新部署前**的前置准备；不要在已部署业务或依赖云厂商安全/审计组件的环境中直接执行。

```bash
sudo ./install.sh
# 选择「8. DD 系统重装 (云环境就绪检查 / 全新部署前置准备)」
```

脚本将执行交互式前置检查：

1. **云厂商检测** — 通过 DMI/SMBIOS/ACPI/网络元数据自动识别厂商
2. **集成项扫描** — 检测 systemd 服务、运行进程、已安装包、文件路径、cron 任务，以及与云厂商相关的仓库/信任材料
3. **就绪审查** — 输出 `cloud metadata` / `cloud-init` / SSH keys / 安全组 / 控制台监控告警 / 审计代理 / 回滚备份的人工核查清单，不会自动停用、删除或修改云厂商安全代理、监控代理或审计组件
4. **DD 重装** — (可选) 使用 `bin456789/reinstall` 在确认后进行全盘重装

> **注意**: DD 重装会清除所有数据并重启。仅在全新部署前使用；执行前必须确认备份、控制台访问、SSH key 恢复方式、安全组回滚路径，以及监控/审计依赖是否允许重装。

---

## Step 1: 部署 Server B (海外)

### 1.1 下载部署脚本

如果这台机器在腾讯云或其他国内线路，第一次 `git clone` 前先确认 GitHub 能访问；如果不通，先按 Server A / Server B 实操文档里的 `/etc/hosts` 方案修好，再回来执行 clone。
因为这一步还没有把仓库拉下来，所以此时不能先用 `./install.sh --github-hosts-repair`。

```bash
# SSH 登录 Server B
ssh root@your-server-b-ip

# 下载脚本（方式一：Git）
git clone https://github.com/ZRainbow1275/bifrost.git
cd bifrost

# 下载脚本（方式二：直接下载）
wget https://github.com/ZRainbow1275/bifrost/archive/main.tar.gz
tar xzf main.tar.gz
cd bifrost-main

# 确认工作区状态
git status --short --branch
```

### 1.2 运行部署

```bash
sudo ./install.sh
```

选择 **「1. 部署海外服务器 (Server B)」**

### 1.3 部署过程

脚本将自动完成以下步骤（每步会显示进度）：

1. **系统环境检测** — 检测 OS、硬件、网络
2. **安全加固** — SSH 加固、防火墙、fail2ban、内核参数
3. **Xray 安装** — 安装 Xray-core，配置 VLESS+Reality
4. **白名单路由** — 配置 AI 域名白名单
5. **3x-ui 安装** — (可选) 安装可视化管理面板
6. **Hysteria 2** — (可选) 安装备用隧道协议
7. **Caddy 部署** — 反向代理 + 伪装网站
8. **BBR 优化** — 启用 TCP BBR 拥塞控制
9. **Netdata 监控** — 部署系统监控

### 1.4 (推荐) 部署 DPI 防护

部署完 Server B 基础组件后，建议立即部署反深包检测防护：

```bash
sudo ./install.sh
# 选择「10. DPI 防护部署 (反深包检测)」
```

DPI 防护将配置：

- **Reality dest 池** — 多个 TLS 1.3 + H2 目标站，通过 openssl 自动验证
- **定时 dest 轮换** — cron 每周自动轮换 dest，Xray 热加载配置
- **uTLS 指纹伪装** — 模拟 Chrome/Firefox/Edge/Safari 的 TLS Client Hello
- **Mux + padding** — 流量分析对抗，防止流量特征识别
- **主动探测防御** — Xray fallback 链配置，防止主动探测

### 1.5 记录连接信息

部署完成后，屏幕将显示连接信息，格式如下：

```
============================================
  Server B 连接信息 - 请妥善保管！
============================================
服务器 IP:     xxx.xxx.xxx.xxx
端口:         443
UUID:         xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
Public Key:   xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
SNI:          dl.google.com
Short ID:     (空或 0123456789abcdef)
============================================
```

**请务必记录以上信息**，部署 Server A 时需要输入。

信息同时保存在: `/root/ai-gateway-connection.txt`

---

## Step 2: 部署 Server A (国内)

### 2.1 准备

- 确保 Server B 已部署完成
- 准备好 Server B 的连接信息
- TLS 入口二选一：
  - 长期生产推荐：准备一个 ICP 备案域名，使用默认 `BIFROST_SERVER_A_TLS_MODE=domain`
  - 腾讯云等暂不绑定域名的真实测试：使用 `BIFROST_SERVER_A_TLS_MODE=ip`，脚本会通过 Certbot 5.4+ 申请 Let's Encrypt 短生命周期 IP 证书，并把证书显式接入 Caddy

### 2.2 运行部署

如果这台机器在腾讯云或其他国内线路，第一次 `git clone` 前先确认 GitHub 能访问；如果不通，先按 Server A / Server B 实操文档里的 `/etc/hosts` 方案修好，再回来执行 clone。
因为这一步还没有把仓库拉下来，所以此时不能先用 `./install.sh --github-hosts-repair`。

```bash
# SSH 登录 Server A
ssh root@your-server-a-ip

# 下载脚本
git clone https://github.com/ZRainbow1275/bifrost.git
cd bifrost
git status --short --branch

# 域名模式（默认）：需要域名解析到 Server A，并满足国内服务器备案前提
sudo ./install.sh

# IP HTTPS 模式：不绑定域名，用 Server A 公网 IPv4 申请 Let's Encrypt IP 证书
# 证书有效期约 160 小时，脚本会配置 8 小时一次的 certbot renew timer
export BIFROST_SERVER_A_TLS_MODE=ip
export BIFROST_SERVER_A_PUBLIC_IP=<SERVER_A_PUBLIC_IPV4>
export BIFROST_ACME_EMAIL=<your-email@example.com>  # 可选，但推荐
sudo ./install.sh
```

选择 **「2. 部署国内服务器 (Server A)」**

### 2.3 部署过程

脚本将要求输入 Server B 的连接信息，然后自动完成：

1. **系统环境检测**
2. **安全加固**
3. **输入 Server B 连接信息** — UUID、PublicKey、IP、Port、SNI
4. **Xray 客户端安装** — 配置 VLESS+Reality 连接 Server B
5. **Docker 安装** — 安装 Docker CE
6. **New API 部署** — Docker Compose 部署 AI API 网关
7. **伪装网站部署** — 正常企业网站
8. **Caddy 部署** — 反向代理到 New API；域名模式走 Caddy 自动证书，Cloudflare 模式走 Origin CA 文件，IP 模式走 Certbot `shortlived` IP 证书
9. **Netdata 监控**
10. **连通性测试** — 自动测试隧道和 API 网关

### 2.4 部署完成

部署完成后将显示：
- New API 管理面板地址
- API 端点地址
- 用户配置示例

注意：New API 管理员账号由首次访问初始化页面时创建，脚本不会再输出或假定共享默认密码。

### 2.5 无备案域名时的 IP HTTPS 模式

当 Server A 位于腾讯云等国内云厂商且暂不绑定备案域名时，可以显式启用 IP HTTPS：

```bash
export BIFROST_SERVER_A_TLS_MODE=ip
export BIFROST_SERVER_A_PUBLIC_IP=<SERVER_A_PUBLIC_IPV4>
export BIFROST_ACME_EMAIL=<your-email@example.com>
sudo ./install.sh
# 选择「2. 部署国内服务器 (Server A)」
```

这个模式的部署合同：

- 使用 Let's Encrypt IP address certificate，必须请求 `shortlived` profile。
- 依赖 Certbot 5.4+ 的 `--ip-address` 与 `--webroot` 支持；Ubuntu 22.04 默认 apt 源可能版本不足，脚本默认用 snap 安装/更新 Certbot。
- 证书路径为 `/etc/letsencrypt/live/<SERVER_A_PUBLIC_IPV4>/fullchain.pem` 和 `/etc/letsencrypt/live/<SERVER_A_PUBLIC_IPV4>/privkey.pem`，Caddy 通过 `tls <fullchain> <privkey>` 显式加载。
- 证书有效期约 160 小时，脚本会保留 HTTP-01 challenge webroot，并创建 `bifrost-certbot-renew.timer` 每 8 小时尝试续期。
- 云安全组和系统防火墙必须允许公网访问 Server A 的 `80/tcp` 与 `443/tcp`；`80/tcp` 不开放会导致续期失败。
- IP 变化后必须重新运行 Server A Caddy/IP 证书配置，旧 IP 证书不会自动覆盖新 IP。

域名模式仍是长期生产推荐路径；IP HTTPS 模式用于没有备案域名时把真实服务器测试链路先跑通。

---

### 2.6 Cloudflare Origin CA 一键域名模式

如果域名通过 Cloudflare 代理到 Server A，推荐使用 Cloudflare Origin CA 证书，并在 Cloudflare 面板把 SSL/TLS 加密模式设置为 **Full (strict)**。这个模式会在 Caddy 启动前检查证书和私钥文件，避免部署到最后才出现 `open ... origin.pem: The system cannot find the file specified` 这类错误。

```bash
export BIFROST_SERVER_A_TLS_MODE=cloudflare-origin
export BIFROST_SERVER_A_DOMAIN=api.example.com
export BIFROST_CLOUDFLARE_ORIGIN_CERT=/etc/caddy/certs/api.example.com-origin.pem
export BIFROST_CLOUDFLARE_ORIGIN_KEY=/etc/caddy/certs/api.example.com-origin.key
export BIFROST_EXPOSURE_PROFILE=vpn-first
export BIFROST_NEW_API_IMAGE="calciumion/new-api:<fixed-version-or-digest>"

sudo ./install.sh --server-a
```

Cloudflare 侧必须同时满足：

- DNS：`api.example.com` 的 `A` 记录指向 Server A 公网 IP，代理状态为 Proxied。
- SSL/TLS：Overview 选择 `Full (strict)`；不要使用 Flexible。
- Origin Server：生成 Origin Certificate 和 Private Key 后，分别保存到上面两个路径；文件必须非空且 Caddy 运行用户可读取。
- Cache Rules：对 `api.example.com` 的 `/v1/*`、`/api/*`、`/dashboard*`、`/login`、`/static/*`、`/logo.png` 选择 Bypass cache。
- WAF / Security Rules：生产推荐保留 `vpn-first`，管理路径只允许 VPN/私网/可信来源访问；如必须公网管理，显式设置 `BIFROST_EXPOSURE_PROFILE=public-managed` 并配置 Cloudflare WAF 来源限制和限速。

### 2.7 New API 数据库与 compose 门禁

脚本默认使用 New API 的本地数据目录和 Redis，避免无意引入 PostgreSQL volume 密码漂移。如果要使用 PostgreSQL，必须显式开启：

```bash
export BIFROST_NEW_API_DB=postgres
export BIFROST_NEW_API_POSTGRES_PASSWORD='<strong-existing-or-new-password>'
sudo ./install.sh --server-a
```

一键部署会执行以下门禁：

- 生成并复用 `/opt/new-api/.env`，不会每次运行都重置 `SESSION_SECRET` 或数据库密码。
- 生成 `SQL_DSN=postgres://...@postgres:5432/new-api?sslmode=disable`，避免容器内 PostgreSQL TLS 噪音。
- 在 `docker compose up -d` 前执行 `docker compose config --quiet`。
- 强制 New API 只绑定 `127.0.0.1:3000:3000`，公网入口只能走 Caddy。
- 如果检测到 PostgreSQL `password authentication failed` / `SQLSTATE 28P01`，会提示恢复旧 `.env`、提供旧密码或做显式迁移/重建，而不是继续伪装成功。

---

## Step 2a: 部署企业 VPN (Server A)

VPN 是 v2.0 架构的**第一道安全门**，所有员工必须先连接 VPN 才能访问内部 AI 服务。

```bash
sudo ./install.sh
# 选择「9. 企业 VPN 部署 (WireGuard/OpenVPN)」
```

部署过程：

1. **前置检查** — 操作系统、内核版本、内存、磁盘
2. **VPN 类型选择** — Firezone (推荐，带 Web GUI) 或 Headscale (Mesh VPN)
3. **网络配置** — VPN 子网 (10.8.0.0/24)、服务子网 (172.16.0.0/24)
4. **防火墙配置** — iptables 网络隔离（服务端口仅 VPN 可访问）
5. **部署完成** — 获取管理面板地址和初始凭据

> 详细部署和用户管理说明请参阅 [VPN-SETUP.md](VPN-SETUP.md)。

---

## Step 2b: 部署 Mihomo 智能路由 (Server A)

Mihomo 替代 Xray 成为中心路由引擎，负责所有流量分流决策：

```bash
sudo ./install.sh
# 选择「11. Mihomo 智能路由部署」
```

路由规则：
- **AI 域名** → 走 Xray 代理 → Server B → AI API
- **国内域名** → 直连
- **流媒体域名** → 拒绝
- **其他流量** → 拒绝（白名单模式）

架构变化：
```
New API (Docker)
  → HTTP_PROXY=host.docker.internal:7890
    → Mihomo (mixed-port 7890, 路由决策)
      → Xray (SOCKS5 127.0.0.1:10808, 纯传输)
        → VLESS+Reality → Server B → AI API
```

---

## Step 2c: 部署增强模块 (Server A)

以下模块建议在基础部署完成后依次部署：

### 连接保活

```bash
sudo ./install.sh
# 选择「12. 连接保活部署 (Keepalive + Watchdog)」
```

部署内容：
- TCP keepalive 内核参数优化（应对运营商 NAT 30-120s 超时）
- Xray sockopt keepalive 配置
- 心跳探测服务 (systemd timer, 30s 间隔)
- 服务 Watchdog (10s 检测间隔，自动重启崩溃服务)

### 网络分流

```bash
sudo ./install.sh
# 选择「13. 网络分流部署 (Split Tunnel)」
```

部署内容：
- 网络分段隔离 (VPN / Services / Docker 子网)
- iptables 精细流量控制
- DNS 分流解析 (AI 域名走 DoH 代理，国内域名走 DoH 直连)

### 备份管理

```bash
sudo ./install.sh
# 选择「14. 备份与恢复管理」
```

功能：
- 加密配置备份 (openssl AES-256)
- 定时自动备份 (每日 cron)
- 一键恢复
- 紧急 IP 轮换 (Server B IP 变更时自动更新 Xray + Mihomo 配置)

### 多节点管理

```bash
sudo ./install.sh
# 选择「16. 多节点 Server B 管理」
```

功能：
- 添加/移除 Server B 节点
- 节点连通性和延迟测试
- Mihomo proxy-group 自动负载均衡和故障转移

---

## Step 3: 配置 New API

### 3.1 登录管理面板

打开浏览器访问: `https://your-domain.com`（或 `http://SERVER_A_IP:3000`）

使用部署时显示的管理员账号登录。

### 3.2 添加 AI 渠道

1. 进入「渠道」页面
2. 点击「添加新渠道」
3. 配置上游 AI API：

**Claude (Anthropic):**
- 类型: Anthropic Claude
- Base URL: https://api.anthropic.com (默认)
- Key: 你的 Anthropic API Key

**GPT (OpenAI):**
- 类型: OpenAI
- Base URL: https://api.openai.com (默认)
- Key: 你的 OpenAI API Key

**Gemini (Google):**
- 类型: Google Gemini
- Base URL: https://generativelanguage.googleapis.com (默认)
- Key: 你的 Google AI API Key

4. 测试渠道连通性
5. 启用渠道

### 3.3 创建用户 Token

1. 进入「令牌」页面
2. 点击「创建新令牌」
3. 设置：
   - 名称: 用户标识（如 "张三-开发"）
   - 额度: 按需设置
   - 到期时间: 按需设置
   - 模型范围: 选择允许的模型
4. 复制生成的 `sk-xxxxx` 格式 Key
5. 分发给对应用户

---

## Step 4: 创建用户与员工入职

### 4.1 创建用户 (管理员操作)

```bash
sudo ./install.sh
# 选择「17. 用户管理 (VPN + API)」→ 创建用户
# 或直接运行:
sudo bash scripts/user-management.sh create zhangsan
```

创建用户时将自动生成：
- WireGuard VPN 配置文件 + QR 码
- New API Token (sk-xxxxx 格式)
- 个人入职指南 (Markdown 格式)

所有文件保存在: `/etc/bifrost/vpn/users/<username>/`

### 4.2 员工入职流程

将生成的入职指南发送给员工，步骤：

1. **安装 WireGuard** — 下载客户端 ([wireguard.com](https://www.wireguard.com/install/))
2. **导入 VPN 配置** — 导入管理员提供的 `.conf` 文件或扫描 QR 码
3. **连接 VPN** — 激活隧道，验证能 ping 通 10.8.0.1
4. **配置 AI 工具** — 设置环境变量：

```bash
# Claude Code
export ANTHROPIC_BASE_URL=https://your-domain.com
export ANTHROPIC_API_KEY=sk-xxxxx  # 管理员提供

# Codex CLI
export OPENAI_BASE_URL=https://your-domain.com/v1
export OPENAI_API_KEY=sk-xxxxx  # 管理员提供
```

> **重要**: 必须先连接 VPN，然后再使用 AI 工具。未连接 VPN 时 API 端点不可达。

详细配置说明参见: [CLIENT-SETUP.md](CLIENT-SETUP.md) | VPN 详情参见: [VPN-SETUP.md](VPN-SETUP.md)

---

## 日常运维

### 健康检查

```bash
./install.sh --health-check
bash scripts/health-check.sh --verbose
```

当前健康检查除了 `xray` / 隧道 / NewAPI 之外，还会校验 `bifrost-api` 本地 `/health` 与管理员鉴权 `401/403` 语义、`caddy` 服务状态，以及 `https://<DOMAIN>/manage/*` 的 profile-aware 暴露面状态。`vpn-first` 下，公网探测返回 `403` 属于受保护状态；如果检查来源位于 VPN/私网/白名单内并返回 `200`，脚本会继续校验 `/manage/register`、`/manage/docs` 前缀契约并提示仍需从非白名单公网来源验证拒绝访问。结果会落到 `/var/log/bifrost/health.json`，适合作为真实部署后的第一道验收门。

### 深度诊断

```bash
./install.sh
# 选择「18. 深度诊断 (网络/服务/GFW检测)」
# 或直接运行:
bash scripts/diagnostics.sh full      # 全链路诊断
bash scripts/diagnostics.sh gfw       # GFW 检测分析
bash scripts/diagnostics.sh report    # 导出 JSON 诊断报告
```

默认情况下，诊断报告会写入 `/var/log/bifrost/diagnostic-report.json`；如果当前 shell 无法写入该目录（例如本机非 root 的 Git Bash / 本地预演环境），脚本会自动回退到 `/tmp/bifrost/diagnostic-report.json`，并在终端明确提示 fallback 路径。

### 白名单管理

```bash
./install.sh
# 选择「5. 白名单管理」
```

### 用户管理

```bash
./install.sh
# 选择「17. 用户管理 (VPN + API)」
# 或直接运行:
bash scripts/user-management.sh list               # 列出所有用户
bash scripts/user-management.sh create <username>   # 创建用户
bash scripts/user-management.sh disable <username>  # 禁用用户
bash scripts/user-management.sh guide <username>    # 导出入职指南
```

### VPN 管理

```bash
bash scripts/vpn.sh status          # 查看 VPN 状态
bash scripts/vpn.sh list_users      # 列出所有 VPN 用户
bash scripts/vpn.sh create_user <name>  # 创建 VPN 用户
bash scripts/vpn.sh revoke_user <name>  # 吊销 VPN 用户
```

### 多节点管理

```bash
bash scripts/multi-server.sh list   # 列出所有 Server B 节点
bash scripts/multi-server.sh add    # 添加新节点
bash scripts/multi-server.sh test   # 测试所有节点连通性和延迟
bash scripts/multi-server.sh remove <name>  # 移除节点
```

### 备份与恢复

```bash
bash scripts/backup.sh backup       # 立即创建加密备份
bash scripts/backup.sh restore      # 列出并恢复备份
bash scripts/backup.sh auto         # 设置每日自动备份 cron
bash scripts/backup.sh rotate-ip <新IP>  # 紧急 IP 轮换 (Server B IP 变更)
```

### 查看监控

- Netdata: `http://127.0.0.1:19999` (仅 VPN 或本地访问，远程请使用 SSH 隧道: `ssh -L 19999:127.0.0.1:19999 root@SERVER_IP`)
- New API 面板: `https://your-domain.com` (仅 VPN 可访问)
- 3x-ui 面板: `https://SERVER_B_IP:PANEL_PORT/PANEL_PATH`

### 更新组件

```bash
./install.sh
# 选择「15. 组件更新管理」
# 或直接运行:
bash scripts/update.sh check        # 检查可用更新 (dry run)
bash scripts/update.sh xray         # 更新 Xray
bash scripts/update.sh mihomo       # 更新 Mihomo
bash scripts/update.sh new-api      # 更新 New API
bash scripts/update.sh geoip        # 更新 GeoIP 数据库
bash scripts/update.sh all          # 更新所有组件
```

---

## 暴露面 Profile

Bifrost 现在通过 `BIFROST_EXPOSURE_PROFILE` 明确区分部署暴露面，避免把管理面默认暴露到公网。

| Profile | 用途 | 管理面策略 |
|---------|------|------------|
| `vpn-first` | 生产推荐默认值 | `/dashboard`、New API 前端静态资源、`/manage`、Server B `/xui-panel/` 仅允许 VPN/私网/来源白名单访问 |
| `public-managed` | 兼容需要公网管理入口的部署 | 管理面经 HTTPS 暴露，必须额外配置强密码、WAF、来源白名单、审计与限速 |
| `lab` | 临时实验环境 | 允许更宽松暴露，仅用于非生产测试 |

示例：

```bash
# 生产推荐：不设置也默认 vpn-first
export BIFROST_EXPOSURE_PROFILE=vpn-first
export BIFROST_ADMIN_ALLOWED_RANGES="127.0.0.1,10.8.0.0/24,172.16.0.0/24"

# 兼容模式：明确选择 public-managed，并在云防火墙/WAF 中收紧来源
export BIFROST_EXPOSURE_PROFILE=public-managed
```

生产环境还会拒绝未显式允许的 `New API` 可变镜像标签。请设置 `BIFROST_NEW_API_IMAGE` 为固定版本或 digest；临时实验才使用 `BIFROST_ALLOW_UNPINNED=1`。

```bash
export BIFROST_NEW_API_IMAGE="calciumion/new-api:<fixed-version-or-digest>"
```

## Server A v0.6 hardening

Server A v0.6 keeps the existing `domain`, `cloudflare-origin`, and `ip` TLS modes for compatibility, but the recommended hardened path is:

```bash
export BIFROST_EXPOSURE_PROFILE=vpn-first
export BIFROST_SERVER_A_TLS_MODE=internal
export BIFROST_ADMIN_ALLOWED_RANGES="10.8.0.0/24,127.0.0.1"
bash ./install.sh --server-a
```

Runtime values that must survive upgrades are persisted in `/etc/bifrost.env`, including `BIFROST_WG_PORT` and optional `BIFROST_FIREWALL_BACKEND`. Migration details are in `docs/MIGRATION-v0.6.md`; internal CA distribution and rotation are in `docs/CA-MANAGEMENT.md`.

---

## Server B 私有分发栈

`prompts/0519-1` 对应的分发栈把 Verdaccio、静态 files、git mirror、NewAPI、PostgreSQL、Redis 下沉到 Server B。Server A 默认转为纯入口网关：TLS 终止、WireGuard hub、Caddy reverse_proxy、bifrost-api 管理面。团队成员仍访问 `https://api.uuhfn.cloud`、`https://npm.uuhfn.cloud`、`https://files.uuhfn.cloud`，不会直接接触 Server B。

### 部署前置条件

1. Server A 已有 WireGuard hub，wg0 地址为 `10.8.0.1/24`。
2. Server B 已加入同一 WireGuard 网络，wg0 地址为 `10.8.0.2/24`，并能从 A 访问。
3. DNS 灰云或等价直连：`api.uuhfn.cloud`、`npm.uuhfn.cloud`、`files.uuhfn.cloud` 指向 Server A 公网 IP。
4. Server B 需要 Docker、Caddy、nftables、fcgiwrap、restic；`server-b.sh --enable-distribution` 会安装/渲染这些依赖。
5. 若要启用 bifrost-api `/mirrors/logs` 与 `/mirrors/disk`，先生成专用只读 SSH key，不复用 root 私钥。

### Server B 启用

```bash
ssh root@<SERVER_B_PUBLIC_IP>
cd /opt/bifrost

# 可选：提供 bifrost-api 只读日志通道公钥
export BIFROST_READONLY_SSH_PUBLIC_KEY="$(cat /etc/bifrost-api/ssh/bifrost-readonly.ed25519.pub)"

bash scripts/server-b.sh --enable-distribution
bash scripts/diagnostics.sh --check distribution
```

脚本会执行这些动作：

- 检查 `wg0` 已存在，避免服务误绑公网。
- 渲染 Verdaccio、NewAPI compose、Caddy、nftables、systemd、restic 配置。
- 创建 `git-mirror` 与 `bifrost-readonly` 专用用户。
- 写入 `DOCKER-USER` 阻断规则，防止 Docker 端口绕过 nftables 从公网泄露。
- 初始化 Verdaccio `team` bootstrap 账号。密码只显示一次，并写入 `/root/.verdaccio-bootstrap-pwd.txt`，不会写入 deploy state。
- 启动 `git-mirror@claude-for-legal-zh.timer`、`verdaccio.service`、`restic-to-a.timer`。

重复执行 `--enable-distribution` 是幂等的；已完成 step 会通过 `/var/lib/bifrost/distribution.step-state` 跳过。

### Server A 入口模式

Server A 现在默认是 distribution gateway，不再默认本地安装 NewAPI：

```bash
export BIFROST_SERVER_A_NEWAPI_MODE=distribution  # 默认值，可不设置
export BIFROST_SERVER_B_WG_IP=10.8.0.2
export BIFROST_DISTRIBUTION_DOMAIN=uuhfn.cloud     # 可选；未设置时从主域名推导
sudo ./install.sh
# 选择「2. 部署国内服务器 (Server A)」
```

Caddy 会把：

- `api.<domain>` 反代到 `http://10.8.0.2:3000`
- `npm.<domain>` 反代到 `http://10.8.0.2:4873`
- `files.<domain>` 反代到 `http://10.8.0.2:8081`
- `files.<domain>/git/*` 反代到 `http://10.8.0.2:8082`

如确需旧模式在 Server A 本机安装 NewAPI，必须显式选择：

```bash
export BIFROST_SERVER_A_NEWAPI_MODE=legacy
sudo ./install.sh
```

### bifrost-api 只读镜像源面板

在 Server A 的 bifrost-api 环境中配置：

```bash
export BIFROST_SERVER_B_WG_IP=10.8.0.2
export BIFROST_READONLY_SSH_KEY=/etc/bifrost-api/ssh/bifrost-readonly.ed25519
export BIFROST_READONLY_USER=bifrost-readonly
```

可用只读接口：

```bash
curl -H "X-Admin-Key: <admin-key>" https://<domain>/manage/mirrors/status
curl -H "X-Admin-Key: <admin-key>" "https://<domain>/manage/mirrors/logs?service=verdaccio&tail=200"
curl -H "X-Admin-Key: <admin-key>" https://<domain>/manage/mirrors/disk
```

`/mirrors/status` 在 Server B 不可达时会返回各服务 `up=false`，不会把 SSH 私钥路径或底层堆栈泄露给客户端。`/mirrors/logs` 和 `/mirrors/disk` 依赖专用 forced-command SSH key，缺失时 fail closed。

### 切流验收

本仓库提供脚本和合同测试，但真实生产切流必须在两台服务器上执行：

```bash
# 本地或运维机 dry-run，先看命令列表
bash scripts/e2e-distribution-rehearsal.sh

# 维护窗口内真实执行
BIFROST_SERVER_A_HOST=<server-a-ssh-host> \
BIFROST_SERVER_B_HOST=<server-b-ssh-host> \
BIFROST_DOMAIN=uuhfn.cloud \
bash scripts/e2e-distribution-rehearsal.sh --execute
```

真实验收至少包括：

- `bash scripts/diagnostics.sh --check distribution` 在 Server B 全 PASS。
- `curl -I https://npm.uuhfn.cloud/` 返回 Verdaccio。
- `git ls-remote https://files.uuhfn.cloud/git/claude-for-legal-zh.git` 成功。
- `curl https://api.uuhfn.cloud/api/status` 返回 NewAPI 状态。
- `nmap -p- <SERVER_B_PUBLIC_IP>` 只剩 `22/tcp` 与配置的 WireGuard UDP 端口（如 `${BIFROST_SERVER_B_WG_PORT:-51820}`）这类预期入口。
- `restic snapshots` 在 Server A 备份仓库能看到 Server B 来源快照。

### 回滚

如果切流失败：

```bash
# Server A: 回退 Caddy 到上一份配置或 legacy NewAPI 模式
cp /etc/caddy/Caddyfile.bak.<timestamp> /etc/caddy/Caddyfile
systemctl reload caddy || systemctl restart caddy

# Server B: 停止分发服务但保留数据
bash scripts/server-b.sh --disable-distribution

# DNS: 如仍保留 Windows VPS 冷备，可临时把 npm/files/api 记录切回旧入口
```

不要在故障窗口直接删除 `/var/lib/verdaccio`、`/var/lib/new-api-pg`、`/var/lib/git-mirrors` 或 `/var/lib/dist`。这些目录是回滚和事后取证的数据源。

### 团队 NewAPI 账号重建

本次 NewAPI 是绿启策略，不迁移旧库。切流后：

1. 管理员在新 NewAPI 首次初始化页面创建强密码管理员账号。
2. 重新创建团队成员账号和 token，旧 Windows VPS / Server A legacy token 作废。
3. 把新的 `base_url=https://api.uuhfn.cloud/v1` 与 token 发给成员。
4. 成员替换 cc-switch、Claude Code、OpenAI-compatible 客户端中的 key。
5. 保留旧 NewAPI 最终快照 30 天，仅用于审计和找回配置，不再接受新写入。

### Windows VPS 退役

迁移稳定后执行最终快照脚本：

```powershell
pwsh -File scripts/legacy-vps-final-snapshot.ps1 `
  -VerdaccioDir C:\verdaccio\storage `
  -CaddyDir C:\caddy `
  -GitMirrorDir C:\git-mirrors `
  -OutputDir C:\bifrost-final-snapshot
```

建议节奏：

- T+0：B 上分发栈完成，DNS 指向 A。
- T+7：确认 npm/files/git/NewAPI/restic 连续稳定，拉取 Windows VPS final snapshot。
- T+8：关机退订 Windows VPS。
- T+30：清理 final snapshot 下载链接和旧 token 记录。

---

## Server B 内部 Claude marketplace

`prompts/0519-1/marketplace-bootstrap/` 引入的内部 Claude Code plugin marketplace 在 Server B 上承载，团队成员通过 `panel.uuhfn.cloud` 管理上传/curate，普通使用走 `files.uuhfn.cloud/git/bifrost-internal-plugins.git` 只读 clone。设计文档见 `.trellis/tasks/05-19-server-b-claude-artifacts-marketplace-visual-panel/spec.md`。

> 安全边界与 ADR-4（internal-only LICENSE）见 `docs/SECURITY.md` 中"Server B 内部 Claude marketplace 安全边界"小节。

### 部署前置条件

1. Server B 私有分发栈（上一节）已经启用：`bash scripts/server-b.sh --enable-distribution` 跑过，`/var/lib/git-mirrors`、`/var/lib/dist`、`/var/log/marketplace` 三个目录存在。
2. DNS：在域名提供商把 `panel.uuhfn.cloud` 的 `A` 记录指向 Server A 公网 IP（Caddy 反代到 bifrost-api）。`panel.uuhfn.cloud` 已由 Server A Caddy 合同接管：非 `{{ADMIN_ALLOWED_RANGES}}` 来源会直接 403，VPN/管理网段内访问 SPA；`/marketplace/*` 和 `/api/*` 作为后端 API 路由反代到 bifrost-api。
3. bifrost-api 已经配置 `BIFROST_ADMIN_KEY`（参考"暴露面 Profile"小节），并且独立的 `bifrost-admin` SSH key 已经写入 Server B 的 `~bifrost-admin/.ssh/authorized_keys`。
4. `prompts/0519-1/team-config/.claude/settings.json.template` 中的 `extraKnownMarketplaces.bifrost-internal.source.url` 应该是 `https://files.uuhfn.cloud/git/bifrost-internal-plugins.git`（PR-6 默认值，无 `git+` 前缀；`source.source = "url"`）。

### Server B 启用 marketplace

`bash scripts/server-b.sh --enable-distribution` 内置 step 07 `_distribution_render_marketplace_scripts`，会一并完成：

- 渲染 `/usr/local/bin/render-marketplace-json.sh`、`/usr/local/bin/check-upstream-schema.sh`
- 初始化 `bifrost-internal-plugins.git` bare 仓库（在 `/var/lib/git-mirrors/`）
- 写入 LICENSE / NOTICE / state.json 初始内容（ADR-4 internal-only baseline）
- 启用 `marketplace-render.path` 和 `upstream-schema-check.timer`

启动后验证：

```bash
systemctl is-active marketplace-render.path upstream-schema-check.timer
ls /var/lib/git-mirrors/bifrost-internal-plugins.git/HEAD
cat /var/lib/dist/plugins/state.json | jq .
dig +short panel.uuhfn.cloud
```

### Server A 部署可视化面板

面板源码在 `bifrost-api-web/`，构建产物由 Server A Caddy 从 `/var/www/bifrost-api-web/dist/` 提供：

```bash
cd bifrost-api-web
pnpm install --frozen-lockfile
pnpm lint
pnpm test
pnpm build

cd ..
bash ./install.sh --deploy-panel
# 或直接：
bash ./scripts/server-a.sh --deploy-panel
```

`--deploy-panel` 默认复制 `bifrost-api-web/dist/` 到 `/var/www/bifrost-api-web/dist/`，可用 `BIFROST_PANEL_SOURCE_DIR` 和 `BIFROST_PANEL_DIST_DIR` 覆盖。部署后从 VPN/管理网段内访问 `https://panel.uuhfn.cloud/`，使用 `X-Admin-Key` 登录。

### Admin 上传 plugin SOP

唯一合法上传通道是 `panel.uuhfn.cloud → bifrost-api admin endpoint → bifrost-admin SSH → 仓库 push`。fcgiwrap 已经 403 阻断 `git-receive-pack`，开发者无法直接 push 到 bare 仓库。

完整流程：

```bash
# 1. 本地 clone（read-only 通道）
git clone https://files.uuhfn.cloud/git/bifrost-internal-plugins.git
cd bifrost-internal-plugins

# 2. 添加新 plugin 目录 plugins/<name>/
mkdir -p plugins/my-plugin/.claude-plugin
cat > plugins/my-plugin/.claude-plugin/plugin.json <<JSON
{"name":"my-plugin","version":"0.1.0","description":"..."}
JSON
cat > plugins/my-plugin/manifest.yaml <<YAML
version: "0.1.0"
description: "What this plugin does"
license_id: "ALL-RIGHTS-RESERVED"
maintainers:
  - {name: "Alice", email: "alice@uuhfn.cloud"}
requires:
  claude_code_min_version: "2.1.0"
permissions:
  declared_skills: ["hello"]
YAML

# 3. 本地测试通过后打 tarball
tar czf my-plugin-v0.1.0.tar.gz -C plugins/my-plugin .

# 4. 浏览器走 VPN/管理网段访问 https://panel.uuhfn.cloud/upload
#    上传 tarball + manifest.yaml；X-Admin-Key 来自管理员

# 4'. 或者直接 curl（脚本化场景）
ADMIN_KEY=$(cat ~/.bifrost-admin-key)   # 不要落盘 commit
curl -X POST \
     -H "X-Admin-Key: ${ADMIN_KEY}" \
     -F "tarball=@my-plugin-v0.1.0.tar.gz" \
     -F "manifest=@plugins/my-plugin/manifest.yaml" \
     https://panel.uuhfn.cloud/marketplace/admin/upload

# 5. bifrost-api 接收后会通过 bifrost-admin SSH 到 Server B
#    bifrost-admin-router.sh 解 tarball → commit → tag plugins/my-plugin/v0.1.0
#    → marketplace-render.path 触发 → state.json 更新 last_render_ts
```

成功响应：

```json
{
  "success": true,
  "data": {
    "tag_created": "plugins/my-plugin/v0.1.0",
    "git_head_sha": "abc123...",
    "audit_id": "550e8400-e29b-41d4-a716-446655440000"
  }
}
```

所有动作落到 `/var/log/marketplace/admin-audit.log`（Server B），可通过 bifrost-api `/marketplace/logs?service=admin-audit` 读取。

### 版本回退 / curate

发布有问题的版本后，admin 可以走两条路：

1. **直接 tag 回退**：把 `manifest.yaml` 中 `version` 改回上一个稳定版本，重新走"Admin 上传"流程，annotated tag 会指向新 commit。`/plugin install <name>@bifrost-internal` 默认拉最新 tag。
2. **/marketplace/admin/curate（feature/deprecate）**：在 `marketplace.json.metadata` 标注 `deprecated`，团队成员 `/plugin marketplace update` 后会看到警告，但已安装的版本仍可用。

curate 调用示例：

```bash
curl -X POST \
     -H "X-Admin-Key: ${ADMIN_KEY}" \
     -H "Content-Type: application/json" \
     -d '{"plugin":"my-plugin","action":"deprecate","reason":"v0.1.0 has CVE"}' \
     https://panel.uuhfn.cloud/marketplace/admin/curate
```

### 团队成员日常使用

成员侧零状态：

```bash
# 1. 拷贝 settings 模板
mkdir -p ~/.claude
cp prompts/0519-1/team-config/.claude/settings.json.template ~/.claude/settings.json

# 2. 启动 claude
claude

# 3. 在 TUI 内
/plugin marketplace update bifrost-internal      # 同步最新 marketplace.json
/plugin install my-plugin@bifrost-internal       # 安装最新版
/plugin install my-plugin@bifrost-internal --version v0.1.0   # 钉版本

# 安装路径：
# ~/.claude/plugins/cache/bifrost-internal/my-plugin/v0.1.0/
```

`/plugin marketplace update bifrost-internal` 后面会 `git ls-remote` 到 `https://files.uuhfn.cloud/git/bifrost-internal-plugins.git`，需要 VPN/管理网段可达。

### CLAUDE_CODE_PLUGIN_SEED_DIR 离线模式

对于 VPN 不通 / 出差 / 干净笔记本，先用 `scripts/build-marketplace-seed.sh` 在内网打包：

```bash
# 在能访问 marketplace 的工作站
bash scripts/build-marketplace-seed.sh --output dist/marketplace-seed.tar.gz
# 会同时写出 dist/marketplace-seed.tar.gz.sha256
```

把两个文件用任意旁路通道（U 盘 / 内部 S3 / Verdaccio file-store）分发到目标机：

```bash
# 目标机
sha256sum -c marketplace-seed.tar.gz.sha256
mkdir -p ~/marketplace-seed
tar xzf marketplace-seed.tar.gz -C ~/marketplace-seed

# 让 Claude Code 直接读 seed，不走网络
export CLAUDE_CODE_PLUGIN_SEED_DIR="$HOME/marketplace-seed/bifrost-internal-plugins"
echo "export CLAUDE_CODE_PLUGIN_SEED_DIR=$HOME/marketplace-seed/bifrost-internal-plugins" >> ~/.bashrc

# 还没设置 settings 的话
mkdir -p ~/.claude
cp ~/marketplace-seed/settings.json.template ~/.claude/settings.json

# 启动；/plugin browse 应能看到 bifrost-internal，即使 wg 没起
claude
```

完整 onboarding 指南见 `prompts/0519-1/marketplace-bootstrap/seed/README.md`。VPN 恢复后跑一次 `/plugin marketplace update bifrost-internal` 就能切回在线模式。

### /plugin marketplace update 同步

成员需要拉取最新发布版本时：

```bash
# TUI 内
/plugin marketplace update bifrost-internal
/plugin install <name>@bifrost-internal
```

如果上游有新 tag，新版本会出现在 `/plugin browse` 中；本地已安装版本不受影响（cache 中按 version 目录存）。

### 故障排查

| 现象 | 排查命令 | 修复 |
|------|----------|------|
| `/plugin browse` 看不到 bifrost-internal | `jq '.extraKnownMarketplaces' ~/.claude/settings.json` | 重新拷贝 PR-6 settings template；确认 `source.source == "url"` 且 url 没有 `git+` 前缀 |
| `git ls-remote` 报 SSL / 拒绝连接 | `curl -I https://files.uuhfn.cloud/` 是否 2xx | 检查 wg0 隧道 (`wg show wg0`)；不通则回退到离线 seed |
| `permission denied` 触发 Bash 工具 | 看 settings 模板中的 `permissions.deny` | 跟 security reviewer 讨论是否新增窄域 `allow`，不要直接删除 `deny` 条目 |
| 上传后 `/plugin marketplace update` 没拉到新版本 | Server B `journalctl -u marketplace-render.service` | bifrost-api `/marketplace/status` 看 `last_render_ts`；render 卡住时手动 `systemctl start marketplace-render.service` |
| `marketplace.json` 解析失败 | `git -C /var/lib/git-mirrors/bifrost-internal-plugins.git show HEAD:.claude-plugin/marketplace.json \| jq .` | 检查 render exit code，多数情况是 manifest.yaml schema 不合规（必填字段缺失或 version 不是 SemVer） |

---

## 注意事项

1. **安全**：定期更换 SSH 密钥和管理面板密码
2. **备份**：定期备份 New API 数据 (`/opt/new-api/data/`)
3. **监控**：关注 Netdata 告警和 New API 渠道状态
4. **白名单**：仅允许 AI 相关域名，严禁开放流媒体
5. **合规**：仅限企业内部使用，不对外提供服务
6. **日志**：定期检查日志，确保无异常流量
