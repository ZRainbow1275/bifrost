# Bifrost - 客户端配置指南 (v2.0)

## 概述

部署完成后，员工需要完成两步才能使用 AI 工具：

1. **连接企业 VPN** (必须) — 安装 WireGuard 客户端，导入管理员提供的配置
2. **配置 AI 工具** — 设置环境变量指向公司 API 网关

> **重要**: 必须先连接 VPN，才能访问 AI API 网关。未连接 VPN 时，API 端点不可达（服务端口仅对 VPN 网络开放）。

---

## 前置条件：连接企业 VPN

### Step 1: 安装 WireGuard 客户端

| 平台 | 安装方式 |
|------|---------|
| **Windows** | 从 [wireguard.com/install](https://www.wireguard.com/install/) 下载 |
| **macOS** | `brew install wireguard-tools` 或从 App Store 安装 |
| **Linux (Ubuntu/Debian)** | `sudo apt install wireguard` |
| **Linux (Fedora/RHEL)** | `sudo dnf install wireguard-tools` |
| **iOS** | App Store 搜索 "WireGuard" |
| **Android** | Google Play 搜索 "WireGuard" |

> 如果公司使用 Headscale 部署，请安装 Tailscale 客户端：[tailscale.com/download](https://tailscale.com/download)

### Step 2: 导入 VPN 配置

管理员会提供 `.conf` 配置文件和/或 QR 码。

**桌面端 (Windows/macOS/Linux):**
1. 打开 WireGuard 应用
2. 点击 "Import tunnel(s) from file"
3. 选择管理员提供的 `.conf` 文件
4. 点击 "Activate" 激活连接

**移动端 (iOS/Android):**
1. 打开 WireGuard 应用
2. 点击 "+" 添加隧道
3. 选择 "Create from QR code"，扫描管理员提供的 QR 码
4. 命名并激活

### Step 3: 验证 VPN 连接

```bash
# 应能 ping 通 VPN 网关
ping 10.8.0.1

# 应能 ping 通服务网关
ping 172.16.0.1
```

Windows 用户在 CMD 或 PowerShell 中运行相同命令。

> VPN 使用 Split Tunnel 模式 — 仅公司内部流量 (10.8.0.0/24, 172.16.0.0/24) 走 VPN，其他上网流量 (YouTube、浏览器等) 不受影响。

### VPN 连接成功后，继续下方配置 AI 工具。

---

## Claude Code

Claude Code 支持通过 `ANTHROPIC_BASE_URL` 环境变量自定义 API 端点。

### 方法 1：环境变量（推荐）

```bash
# 在 ~/.bashrc 或 ~/.zshrc 中添加
export ANTHROPIC_BASE_URL=https://your-domain.com
export ANTHROPIC_API_KEY=sk-xxxxx  # 从 New API 面板获取

# 使配置生效
source ~/.bashrc
```

### 方法 2：Claude Code settings.json

```json
// ~/.claude/settings.json
{
  "env": {
    "ANTHROPIC_BASE_URL": "https://your-domain.com",
    "ANTHROPIC_API_KEY": "sk-xxxxx"
  }
}
```

### 方法 3：单次使用

```bash
ANTHROPIC_BASE_URL=https://your-domain.com ANTHROPIC_API_KEY=sk-xxxxx claude
```

### 企业网络配置

如果公司网络需要通过代理访问，还可配置：

```bash
export HTTPS_PROXY=https://your-domain.com:443
# 或
export HTTP_PROXY=http://your-domain.com:80
```

参考文档：https://docs.anthropic.com/en/docs/claude-code/cli-usage

---

## OpenAI Codex CLI

Codex CLI 支持通过环境变量或 config.toml 自定义 API 端点。

### 方法 1：环境变量

```bash
export OPENAI_BASE_URL=https://your-domain.com/v1
export OPENAI_API_KEY=sk-xxxxx  # 从 New API 面板获取
```

### 方法 2：config.toml

```toml
# ~/.codex/config.toml

# 直接修改内置 provider 的 base URL
openai_base_url = "https://your-domain.com/v1"

# 或配置代理 provider
[model_providers.my-gateway]
base_url = "https://your-domain.com/v1"
env_key = "OPENAI_API_KEY"
```

### 方法 3：代理模式

```toml
# ~/.codex/config.toml
[permissions.network]
proxy_url = "https://your-domain.com"
```

参考文档：https://github.com/openai/codex

---

## OpenCode

```bash
export OPENAI_BASE_URL=https://your-domain.com/v1
export OPENAI_API_KEY=sk-xxxxx
```

---

## Cursor / Continue.dev / 其他 OpenAI 兼容工具

大多数支持 OpenAI API 格式的工具都可以通过以下方式配置：

```bash
export OPENAI_API_BASE=https://your-domain.com/v1  # 旧版变量名
export OPENAI_BASE_URL=https://your-domain.com/v1  # 新版变量名
export OPENAI_API_KEY=sk-xxxxx
```

或在工具的设置界面中：
- API Base URL / Endpoint: `https://your-domain.com/v1`
- API Key: `sk-xxxxx`（从 New API 面板获取）

---

## API Key 获取方式

1. 打开 New API 管理面板：`https://your-domain.com`
2. 使用管理员账号登录
3. 进入「令牌」页面
4. 点击「创建新令牌」
5. 设置名称、配额、到期时间
6. 复制生成的 `sk-xxxxx` 格式 Key

### 为团队成员创建 Key

管理员可以：
- 为每个用户创建独立的 API Key
- 设置每个 Key 的调用配额（按金额或 Token 数）
- 设置 Key 的到期时间
- 限制 Key 可使用的模型

---

## 可用模型

通过 Bifrost，你可以使用以下模型（取决于 New API 中配置的渠道）：

| 提供商 | 模型示例 |
|--------|---------|
| Anthropic | claude-sonnet-4-6, claude-opus-4-6, claude-haiku-4-5 |
| OpenAI | gpt-4o, gpt-4-turbo, o3, o4-mini |
| Google | gemini-2.5-pro, gemini-2.5-flash |
| DeepSeek | deepseek-chat, deepseek-coder |
| Mistral | mistral-large, codestral |

---

## 测速

部署完成后，可以测试连接速度：

```bash
# 测试 API 响应时间
time curl -s -o /dev/null -w "%{time_total}s" \
  -H "Authorization: Bearer sk-xxxxx" \
  https://your-domain.com/v1/models

# 测试模型调用
curl https://your-domain.com/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer sk-xxxxx" \
  -d '{
    "model": "claude-sonnet-4-6",
    "messages": [{"role": "user", "content": "Hello!"}],
    "max_tokens": 100
  }'
```

---

## 常见问题

### Q: 连接超时 / API 端点不可达？
1. **先检查 VPN 是否已连接** — 这是最常见的原因。确认 WireGuard 已激活，能 ping 通 `10.8.0.1`
2. 检查 Server A 是否正常运行：`curl https://your-domain.com/api/status`
3. 联系管理员运行健康检查

### Q: API Key 格式不对？
New API 生成的 Key 格式为 `sk-xxxxx`，与 OpenAI 原生格式相同。确保完整复制。

### Q: 模型不可用？
在 New API 面板「渠道」页面检查上游 API Key 是否有效、余额是否充足。

### Q: 速度慢？
- 建议 Server B 选择日本/香港/新加坡节点
- 确认 BBR 已启用
- 联系管理员检查带宽使用情况

### Q: VPN 连不上？
1. 检查 WireGuard 配置中的 Endpoint 地址是否正确
2. 确认你的网络未封锁 WireGuard 配置 `Endpoint` 中的 UDP 端口；管理员可在服务器 `/etc/bifrost.env` 的 `BIFROST_WG_PORT` 查看当前端口
3. 尝试切换网络环境（部分企业/酒店 WiFi 限制 UDP）
4. 联系管理员检查 VPN 服务状态

### Q: VPN 连上了但 AI 工具还是报错？
1. 确认能 ping 通 `172.16.0.1` (服务子网)
2. 检查环境变量中的 API Base URL 是否正确
3. 联系管理员检查防火墙规则
