# AI Gateway Bridge

> 历史快照提示: `ai-gateway-bridge/` 是旧目录名保留的历史子树，当前主实现、最新审计结果、统一测试入口与部署文档都以仓库根目录的 `install.sh`、`docs/0325/*`、`tests/test-in-docker.sh` 为准。除非明确要回溯历史版本，否则不要把本目录当作当前 authoritative source。

国内外 AI 服务桥接一键部署方案 v2.0 — 让中小企业 (30-100 人) 轻松使用 Claude Code、Codex CLI、OpenCode 等 AI 开发工具。

## 功能特性

### 核心能力

- **一键部署**：交互式 Bash 脚本，全自动完成配置
- **双模式运行**：API 网关（无需客户端）+ 代理模式
- **30+ AI 供应商**：Claude、GPT、Gemini、DeepSeek、Mistral 等
- **安全加固**：SSH 加固、防火墙、fail2ban、内核加固、Lynis 审计
- **流量伪装**：VLESS+Reality 协议，流量不可区分于正常 HTTPS
- **域名白名单**：仅允许 AI API，拒绝流媒体

### v2.0 新增功能

- **企业 VPN 网关**：WireGuard (Firezone/Headscale) 作为第一道安全门，员工必须先连 VPN 才能访问 AI 服务
- **Mihomo 智能路由**：基于规则的流量路由引擎（AI 走代理、国内直连、流媒体拒绝），替代 Xray 路由
- **DPI 防护**：Reality dest 池管理、定时 dest 轮换、uTLS 指纹伪装、Mux+padding 流量混淆
- **DD 系统重装**：预部署云环境就绪审查，自动检测并列出云厂商集成项，需人工确认备份、SSH、监控、审计与回滚依赖后才可选择 DD 全盘重装
- **连接保活**：TCP keepalive 内核参数、Xray sockopt 优化、心跳探测、服务 Watchdog 自动恢复
- **网络分流**：Split Tunnel 网络分段，VPN 用户仅路由内部流量，DNS 分流解析
- **备份与恢复**：加密配置备份、定时自动备份 (cron)、一键恢复、紧急 IP 轮换
- **多节点管理**：多台 Server B 负载均衡与故障转移，Mihomo proxy-group 自动切换
- **用户管理**：统一管理 VPN 凭据 + API Token，员工入职/离职一键操作，导出个人入职指南
- **深度诊断**：系统/服务/网络/DNS/速度全链路诊断，GFW 检测分析，JSON 诊断报告导出
- **组件更新**：安全更新 Xray、Mihomo、New API、GeoIP 数据库，版本检查 (dry run)

## 架构

```
员工设备 (Claude Code / Codex CLI / OpenCode)
  ↓ WireGuard VPN (加密隧道, 第一道门)
VPN Gateway (10.8.0.1) ← Firezone/Headscale 管理
  ↓
Server A (国内)
  ├── Caddy (反向代理 + 自动 HTTPS)
  ├── New API (AI API 网关, 30+ 供应商, VPN-only 访问)
  ├── Mihomo (智能路由引擎: AI→代理, CN→直连, 流媒体→拒绝)
  └── Xray Client (VLESS+Reality 传输层)
        ↓ VLESS+Reality (伪装 HTTPS, DPI 防护 + dest 轮换)
        GFW
        ↓
Server B (海外, 支持多节点负载均衡)
  ├── Xray Server (VLESS+Reality)
  ├── 3x-ui (可视化管理面板)
  └── Caddy (伪装网站)
        ↓ HTTPS
AI API (Claude / GPT / Gemini / DeepSeek / Mistral / ...)
```

## 快速开始

### 推荐部署顺序 (v2.0)

```
Step 0: (可选) DD 系统重装 — 清除云厂商 Agent，获取干净环境
Step 1: 部署 Server B (海外) — Xray 服务端 + 反 DPI 防护
Step 2: 部署 Server A (国内) — Xray 客户端 + Mihomo + New API + VPN
Step 3: 创建 VPN 用户 — 为每位员工生成 VPN 配置 + API Token
Step 4: 员工入职 — 安装 WireGuard → 连接 VPN → 配置 AI 工具
```

### Step 1: 部署海外服务器 (Server B)

```bash
git clone https://github.com/your-org/ai-gateway-bridge.git
cd ai-gateway-bridge
git status --short --branch
sudo ./install.sh
# 选择「1. 部署海外服务器」
# (推荐) 部署完成后选择「10. DPI 防护部署」加固反检测
```

### Step 2: 部署国内服务器 (Server A)

```bash
# 在国内服务器上
sudo ./install.sh
# 选择「2. 部署国内服务器」→ 输入 Server B 连接信息
# 然后依次部署:
#   「9.  企业 VPN 部署」   → WireGuard + Firezone/Headscale
#   「11. Mihomo 智能路由」 → 规则分流引擎
#   「12. 连接保活部署」    → Keepalive + Watchdog
#   「13. 网络分流部署」    → Split Tunnel
#   「14. 备份与恢复管理」  → 自动备份 cron
```

### Step 3: 创建用户并配置 AI 工具

```bash
# 创建员工 VPN 账号 + API Token
sudo ./install.sh
# 选择「17. 用户管理」→ 创建用户

# 员工侧: 先连 VPN，再配置 AI 工具
# Claude Code
export ANTHROPIC_BASE_URL=https://your-domain.com
export ANTHROPIC_API_KEY=sk-xxxxx

# Codex CLI
export OPENAI_BASE_URL=https://your-domain.com/v1
export OPENAI_API_KEY=sk-xxxxx
```

> **重要**: 员工必须先连接企业 VPN，然后才能访问 AI API 网关。详见 [VPN-SETUP.md](docs/VPN-SETUP.md) 和 [CLIENT-SETUP.md](docs/CLIENT-SETUP.md)。

## 系统要求

| 项目 | Server A (国内) | Server B (海外) |
|------|----------------|----------------|
| 系统 | Ubuntu 22.04+, Debian 12+, CentOS 9+ | 同左 |
| 配置 | 2C4G, 5M+ 带宽 | 2C2G |
| 端口 | 80, 443, WireGuard UDP (`BIFROST_WG_PORT`) | 443 |

## 技术栈

| 组件 | 用途 |
|------|------|
| [Xray-core](https://github.com/XTLS/Xray-core) | VLESS+Reality 加密隧道 |
| [Mihomo (Clash.Meta)](https://github.com/MetaCubeX/mihomo) | 智能路由引擎 (规则分流 + proxy-group 负载均衡) |
| [New API](https://github.com/Calcium-Ion/new-api) | AI API 网关 (30+ 供应商) |
| [3x-ui](https://github.com/MHSanaei/3x-ui) | Xray 可视化管理面板 |
| [Caddy](https://caddyserver.com/) | 反向代理 + 自动 HTTPS |
| [WireGuard](https://www.wireguard.com/) | 企业 VPN 隧道 |
| [Firezone](https://www.firezone.dev/) | WireGuard VPN 管理平台 (Web GUI + OIDC) |
| [Headscale](https://github.com/juanfont/headscale) | 自托管 Tailscale 控制服务器 (Mesh VPN) |
| [Netdata](https://www.netdata.cloud/) | 系统监控 |
| [fail2ban](https://www.fail2ban.org/) | 入侵防护 |
| [Lynis](https://cisofy.com/lynis/) | 安全审计 |

## 文档

| 文档 | 说明 |
|------|------|
| [USAGE.md](docs/USAGE.md) | 详细使用说明 (含 v2 完整部署流程) |
| [VPN-SETUP.md](docs/VPN-SETUP.md) | 企业 VPN 部署与员工入职指南 |
| [CLIENT-SETUP.md](docs/CLIENT-SETUP.md) | 客户端配置指南 (VPN + AI 工具) |
| [TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) | 疑难排查 (含 VPN/Mihomo/DPI/Keepalive) |
| [SECURITY.md](docs/SECURITY.md) | 安全说明与合规提醒 |

## 安全说明

- 本工具仅供企业内部合法使用
- 使用前请了解相关法律法规
- 详见 [SECURITY.md](docs/SECURITY.md)

## 许可证

MIT License
