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
- Server A 的 51820/UDP 端口对 VPN 客户端开放（部署 VPN 时需要）
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

# 赋予执行权限
chmod +x install.sh scripts/*.sh
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
- (推荐) 准备一个 ICP 备案域名

### 2.2 运行部署

```bash
# SSH 登录 Server A
ssh root@your-server-a-ip

# 下载脚本
git clone https://github.com/ZRainbow1275/bifrost.git
cd bifrost
chmod +x install.sh scripts/*.sh

# 运行
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
8. **Caddy 部署** — 反向代理到 New API
9. **Netdata 监控**
10. **连通性测试** — 自动测试隧道和 API 网关

### 2.4 部署完成

部署完成后将显示：
- New API 管理面板地址
- 默认管理员账号密码
- API 端点地址
- 用户配置示例

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

---

## 注意事项

1. **安全**：定期更换 SSH 密钥和管理面板密码
2. **备份**：定期备份 New API 数据 (`/opt/new-api/data/`)
3. **监控**：关注 Netdata 告警和 New API 渠道状态
4. **白名单**：仅允许 AI 相关域名，严禁开放流媒体
5. **合规**：仅限企业内部使用，不对外提供服务
6. **日志**：定期检查日志，确保无异常流量
