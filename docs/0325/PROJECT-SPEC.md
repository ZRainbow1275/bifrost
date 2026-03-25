# Bifrost — 项目技术规格书 (AI-Readable)

> 本文档面向 AI 开发助手，提供 Bifrost 项目的完整技术上下文。信息密度优先于可读性。

---

## 1. 项目定位

**一句话**: 为中国大陆中小企业(30-100人)提供一键部署的双服务器架构，桥接国内网络到海外 AI API 服务。

**解决的核心矛盾**: 中国大陆网络无法直连 Claude API / OpenAI API / Gemini API 等海外 AI 服务，且缺乏企业级安全管控（VPN 零信任、域名白名单、用户管理、流量审计）。

**目标用户**: 中小型企业的 IT 管理员。技术水平假设：能 SSH 到服务器执行命令，但不熟悉 Xray/WireGuard/Mihomo 等工具的手动配置。

**交付形式**: 纯 Bash 脚本 + 配置模板 + Python FastAPI 管理服务。零外部依赖（运行时自动安装所需软件）。

---

## 2. 架构

```
┌─────────────────────────────────────────────────┐
│                  用户层                          │
│  Claude Code / Codex CLI / OpenCode / 浏览器     │
│  配置 API Base URL = https://<domain>/v1         │
│  配置 API Key = sk-xxx (NewAPI 签发)             │
└────────────────────┬────────────────────────────┘
                     │ WireGuard VPN (UDP:51820)
                     │ AllowedIPs: 10.8.0.0/24 (split tunnel)
┌────────────────────▼────────────────────────────┐
│              Server A (国内)                     │
│                                                  │
│  Caddy (:443)                                    │
│    ├─ /v1/*  → reverse_proxy localhost:3000      │
│    ├─ /api/* → reverse_proxy localhost:3000      │
│    ├─ /manage/* → reverse_proxy localhost:8000   │
│    └─ / → 伪装企业网站                           │
│                                                  │
│  NewAPI Docker (:3000)                           │
│    ├─ AI API 网关 (OpenAI 兼容格式)              │
│    ├─ 30+ 供应商统一接入                         │
│    ├─ Token/用户/渠道/配额管理                   │
│    └─ HTTP_PROXY=host.docker.internal:7890       │
│                                                  │
│  Bifrost API Docker (:8000)                      │
│    ├─ 用户自助注册 (注册机)                      │
│    ├─ 模型可用性监控                             │
│    ├─ 渠道管理与测试                             │
│    └─ 用量统计                                   │
│                                                  │
│  Mihomo (:7890)                                  │
│    ├─ AI 域名 → xray-vless-reality (SOCKS5)     │
│    ├─ CN 域名 → DIRECT                          │
│    ├─ 流媒体/社交 → REJECT                      │
│    └─ 其余 → REJECT (白名单强制)                │
│                                                  │
│  Xray Client (SOCKS5 :10808, HTTP :10809)        │
│    └─ VLESS+Reality+Vision → Server B            │
│                                                  │
│  WireGuard (:51820/udp)                          │
│    └─ 企业 VPN 网关 (零信任接入)                 │
└────────────────────┬────────────────────────────┘
                     │ VLESS+Reality (TCP, 伪装 HTTPS)
                     │ chrome fingerprint, dest 池轮换
                     │ [穿越 GFW]
┌────────────────────▼────────────────────────────┐
│              Server B (海外)                     │
│                                                  │
│  Xray Server (:PORT, VLESS+Reality)              │
│    └─ outbound: freedom (直连目标)               │
│                                                  │
│  3x-ui (管理面板, Caddy 反代)                    │
│  Caddy (:443, 伪装网站 + TLS)                    │
│  Hysteria 2 (可选, QUIC UDP:443)                 │
└────────────────────┬────────────────────────────┘
                     │ HTTPS
                     ▼
          api.anthropic.com
          api.openai.com
          generativelanguage.googleapis.com
          api.deepseek.com
          ...
```

---

## 3. 技术栈

| 层 | 技术 | 版本 | 用途 |
|----|------|------|------|
| VPN | WireGuard | 内核模块 | 员工零信任接入 |
| VPN 管理 | Firezone / Headscale | 0.7+ / 0.23+ | VPN 用户管理 UI |
| 反向代理 | Caddy v2 | 2.7+ | HTTPS 自动证书 + 反代 |
| AI 网关 | New API (Calcium-Ion) | latest | 30+ AI 供应商统一接口 |
| 管理平台 | FastAPI + httpx | Python 3.12 | 注册机 + 监控 + 管理 |
| 智能路由 | Mihomo (Meta) | 1.18+ | 规则分流 + DNS |
| 隧道协议 | Xray (VLESS+Reality) | 1.8+ | GFW 穿越 + 流量伪装 |
| 备用隧道 | Hysteria 2 | 2.0+ | QUIC 协议备用通道 |
| 防火墙 | iptables + UFW | - | 端口管控 + VPN 隔离 |
| 入侵检测 | fail2ban | 1.0+ | SSH/Caddy 暴力破解防护 |
| 容器 | Docker + Compose | 20.10+ | NewAPI + Bifrost API |
| DPI 防护 | Reality dest 池 + uTLS | - | 流量指纹伪装 |

---

## 4. 文件结构与模块职责

```
bifrost/
├── install.sh                  # 入口: 交互式菜单 + CLI 参数解析
│                                # 调用: scripts/*.sh 中的 *_flow() 函数
│
├── scripts/
│   ├── common.sh               # 1389 行共享库: 日志、OS检测、包管理、Docker、
│   │                           # 菜单UI、网络工具、模板渲染、进度条、错误处理
│   ├── server-a.sh             # Server A 部署: Xray客户端 + NewAPI + Caddy
│   ├── server-b.sh             # Server B 部署: Xray服务端 + 3x-ui + Caddy + Hysteria2
│   ├── security.sh             # 安全加固: SSH + 防火墙 + fail2ban + sysctl + Lynis
│   ├── vpn.sh                  # VPN: WireGuard + Firezone/Headscale + 用户管理
│   ├── mihomo.sh               # Mihomo: 配置渲染 + systemd + 节点管理
│   ├── anti-dpi.sh             # DPI防护: dest池管理 + 轮换 + uTLS + Mux
│   ├── keepalive.sh            # 保活: TCP keepalive + watchdog + heartbeat
│   ├── split-tunnel.sh         # 分流: VPN split tunnel + DNS 分段
│   ├── backup.sh               # 备份: 加密备份 + cron + 恢复 + IP轮换
│   ├── update.sh               # 更新: Xray/Mihomo/NewAPI/GeoIP 版本管理
│   ├── multi-server.sh         # 多节点: Server B 负载均衡 + 故障转移
│   ├── user-management.sh      # 用户: VPN凭据 + API Token + 入职指南
│   ├── diagnostics.sh          # 诊断: 系统/服务/网络/DNS/GFW 全链路
│   ├── health-check.sh         # 健康检查: 服务存活 + API可达 + 自动恢复
│   ├── monitoring.sh           # 监控: Netdata + logrotate
│   ├── whitelist.sh            # 白名单: AI域名管理
│   ├── uninstall.sh            # 卸载: 全组件清理
│   ├── dd-reinstall.sh         # DD重装: 云Agent检测/清理 + 全盘重装
│   └── bifrost-api.sh          # 管理平台: Docker 部署/管理
│
├── bifrost-api/                # FastAPI 管理平台
│   ├── app/
│   │   ├── main.py             # 30 路由, CORS, lifespan
│   │   ├── config.py           # pydantic-settings, BIFROST_ 前缀环境变量
│   │   ├── newapi_client.py    # httpx 异步客户端, 20 方法, 重试机制
│   │   ├── schemas.py          # 14 个 Pydantic 模型
│   │   ├── dependencies.py     # Settings单例 + Client单例 + Admin鉴权
│   │   └── routers/
│   │       ├── register.py     # POST /api/v1/register (自助注册)
│   │       │                   # POST /api/v1/users/batch (批量注册机)
│   │       ├── users.py        # 用户 CRUD + 配额管理
│   │       ├── models.py       # 模型可用性 + 渠道延迟测试
│   │       ├── channels.py     # 渠道 CRUD + 并行连通测试
│   │       └── stats.py        # 用量统计 + 用户/模型排行
│   ├── Dockerfile              # 多阶段构建, 非root运行
│   └── docker-compose.yml      # host.docker.internal:3000 → NewAPI
│
├── configs/
│   ├── xray/                   # VLESS+Reality 配置模板 (client/server)
│   ├── caddy/                  # Caddyfile 模板 (Server A/B)
│   ├── mihomo/                 # Mihomo 配置 + AI域名规则集 + 流媒体阻断规则
│   ├── vpn/                    # WireGuard + Firezone + Headscale + iptables
│   ├── anti-dpi/               # Reality dest 池 + 轮换脚本
│   ├── keepalive/              # watchdog + heartbeat
│   ├── whitelist/              # AI 域名白名单 (42 域名)
│   ├── network/                # iptables 基础规则
│   ├── fail2ban/               # SSH/Caddy 防护
│   └── sysctl/                 # 内核安全加固参数
│
├── docs/
│   ├── USAGE.md                # 完整部署流程 (486 行)
│   ├── VPN-SETUP.md            # VPN 部署详解 (411 行)
│   ├── CLIENT-SETUP.md         # 员工端配置 (255 行)
│   ├── SECURITY.md             # 安全架构 (132 行)
│   └── TROUBLESHOOTING.md      # 故障排查 (623 行)
│
└── tests/
    └── test-in-docker.sh       # Docker 模拟测试 (语法/函数/配置/端口/菜单/文档)
```

---

## 5. 关键数据流

### 5.1 用户注册 → AI 调用 全链路

```
管理员部署 Bifrost
  → NewAPI 启动 (Docker :3000)
  → Bifrost API 启动 (Docker :8000)
  → 管理员设置 AI 渠道 (Claude/GPT key → NewAPI)

员工自助注册
  → POST /manage/api/v1/register {"username":"alice"}
  → Bifrost API → NewAPI: POST /api/user (创建用户)
  → Bifrost API → NewAPI: POST /api/token (创建 Token, 绑定用户)
  → 返回: api_key="sk-xxx", base_url="https://domain/v1"

员工使用 AI 工具
  → Claude Code 配置: ANTHROPIC_BASE_URL=https://domain/v1, API_KEY=sk-xxx
  → Claude Code → WireGuard VPN → Server A
  → Caddy (:443) → NewAPI (:3000)
  → NewAPI 验证 Token → 选择渠道 → HTTP_PROXY → Mihomo (:7890)
  → Mihomo 规则匹配 api.anthropic.com → AI-Proxy → Xray SOCKS5 (:10808)
  → Xray Client → VLESS+Reality → GFW → Xray Server (B)
  → Server B → api.anthropic.com
  → 响应原路返回
```

### 5.2 Mihomo 路由决策树

```
入站流量
  ├─ 私有IP/LAN → DIRECT
  ├─ 广告域名 (geosite:category-ads-all) → REJECT
  ├─ 流媒体/社交 (streaming-block.yaml) → REJECT
  │   包含: Netflix, YouTube, TikTok, Instagram, Twitter, Telegram,
  │         Steam, Epic, Battle.net, torrent, tracker
  ├─ AI 域名 (ai-domains.yaml) → AI-Proxy → xray-vless-reality
  │   包含: anthropic.com, openai.com, googleapis.com(AI),
  │         deepseek.com, mistral.ai, groq.com, cohere.ai,
  │         github.com, huggingface.co, npmjs.org, pypi.org,
  │         docker.io, cursor.sh, v0.dev 等 42 域名
  ├─ 中国域名 (geosite:cn) → DIRECT
  ├─ 中国IP (geoip:CN) → DIRECT
  └─ 其余所有 → REJECT (白名单强制)
```

### 5.3 安全分层

```
第1层: WireGuard VPN (加密隧道 + 身份认证)
  → 无 VPN 不可访问任何内部服务
第2层: Caddy TLS (HTTPS + HSTS + 安全头)
  → 所有 HTTP → HTTPS 重定向
第3层: NewAPI Token (API 级别认证 + 配额控制)
  → 无效 Token 被拒绝
第4层: Mihomo 白名单 (域名级别管控)
  → 仅 AI 域名可代理，其余 REJECT
第5层: Xray VLESS+Reality (流量伪装)
  → DPI 不可区分于正常 HTTPS
第6层: iptables (端口级别隔离)
  → 内部端口 (3000/7890/10808) 仅 VPN/Docker/localhost 可达
第7层: fail2ban + SSH 加固 (入侵防护)
  → 暴力破解自动封禁
第8层: 内核加固 (sysctl)
  → SYN flood 防护, ASLR, 源路由禁用
```

---

## 6. 配置模板渲染机制

**两套并行机制**（当前存在不一致，见审计报告）：

| 机制 | 使用场景 | 模板格式 |
|------|----------|----------|
| `template_render()` | Mihomo, WireGuard | `{{VARIABLE}}` sed 替换 |
| Bash heredoc 内联 | Xray, Caddy, Docker Compose | `${variable}` bash 变量 |

`template_render()` 位于 `common.sh:715-740`，接受 `KEY=VALUE` 对，用 sed 替换 `{{KEY}}`。

---

## 7. 已知问题与技术债务

见 `docs/0325/AUDIT-REPORT.md`，4 BLOCKER + 7 HIGH 需在生产部署前修复。

核心风险:
1. 端口冲突（Xray 443 vs Caddy 443）
2. 防火墙规则不完整（Xray 端口未开放）
3. DNS 端口不匹配（1053 vs 53）
4. 防火墙脚本互斥
5. 配置模板与实际部署代码不同步（死代码）

---

## 8. 开发约定

- 所有 Bash 脚本使用 `set -euo pipefail`
- 共享函数通过 `common.sh` 提供，double-source guard (`_COMMON_SH_LOADED`)
- 日志函数: `log_info`, `log_warn`, `log_error`, `log_success`, `log_step`
- 交互菜单: `show_menu` + `MENU_RESULT` 全局变量
- GitHub 下载: `github_download()` 自动尝试中国镜像
- Docker 安装: `install_docker_china_aware()` 中国镜像源
- 进度显示: `with_spinner "message" command`
- 错误处理: `die "message"` 终止 + `trap cleanup EXIT`
- Python: FastAPI + Pydantic v2 + httpx async + `from __future__ import annotations`
