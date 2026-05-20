# 团队成员上手指南：用 cc-switch 把 Claude Code 切到 DeepSeek V4

> 适用场景：你已经按 `setup.bat` / `setup.sh` 装完 Node + Python + claude-code + trellis + cc-switch，现在要让 Claude Code 跑国产模型（DeepSeek V4），省钱 + 不用翻墙。
> 预计耗时：5 ~ 10 分钟。
> 信息核实日期：2026-05-19（DeepSeek V4 已于 2026-04-24 正式预览发布）。

---

## 0. 你将得到什么

| 项 | 当前 | 配置后 |
|---|---|---|
| Claude Code 后端模型 | Anthropic 官方（需要付费 + 可能翻墙） | DeepSeek V4 Pro/Flash（国内直连，1M context） |
| 切换其他厂商 | 改环境变量重启 | cc-switch 系统托盘一键切 |
| .claude.json / settings.json | 自己摸索 | 团队统一模板，从 VPS 拉 |

---

## 1. 先核对工具是否装好

打开命令行（Windows: CMD / PowerShell；macOS/Linux: Terminal），跑：

```
claude --version
trellis --version
```

两个都要输出版本号。**如果有报错 → 先回去把 setup.bat / setup.sh 跑通**。

同时确认 cc-switch GUI 能打开：
- **Windows**: 开始菜单找 `CC Switch`
- **macOS**: `/Applications/CC Switch.app`
- **Linux**: `~/.local/bin/cc-switch.AppImage`

---

## 2. 申请 DeepSeek API Key

1. 浏览器打开 https://platform.deepseek.com
2. 注册账号（手机号 / GitHub 都行）
3. 左侧 **API Keys** → **Create New API Key**
4. 复制生成的 key（**只显示一次，丢了只能重建**），格式形如 `sk-xxxxxxxxxxxx`
5. 先充值至少 ¥10（V4-Flash 输入 ¥1/M tokens，便宜到飞起，够用很久）

> **DeepSeek V4 定价**（来自官方 + cc-switch 仓库 commit `b1f9ce4`）：
>
> | 模型 | 输入 (per 1M tokens) | 输出 (per 1M tokens) | Context |
> |---|---|---|---|
> | `deepseek-v4-flash` | $0.14 | $0.28 | 1M |
> | `deepseek-v4-pro` | $1.68 | $3.36 | 1M |
>
> 对比参考：Anthropic Sonnet 输出约 $15/1M，**V4-Pro 便宜约 4.5 倍，V4-Flash 便宜约 50 倍**。

---

## 3. 在 cc-switch 里添加 DeepSeek V4 供应商

### 3.1 打开 cc-switch GUI

启动后顶部 Tab 选 **Claude Code**（不是 Codex / Gemini 那些）。

### 3.2 添加 Provider — 用内置 Preset（推荐）

cc-switch v3.14.x **已经内置 DeepSeek V4 preset**，直接用：

1. 点 **Add Provider**（或 **+** 按钮）
2. 在 **Choose Preset** 列表里搜 `DeepSeek`
3. 选 **DeepSeek**（图标蓝色 `DS`）
4. 唯一要填的字段：**API Key** → 粘贴你刚刚申请的 `sk-xxxxx`
5. **Save** / **Add**

cc-switch 会自动写入以下环境变量到 `~/.claude/settings.json`：

```json
{
  "env": {
    "ANTHROPIC_BASE_URL": "https://api.deepseek.com/anthropic",
    "ANTHROPIC_AUTH_TOKEN": "你的 API Key",
    "ANTHROPIC_MODEL": "deepseek-v4-pro",
    "ANTHROPIC_DEFAULT_OPUS_MODEL": "deepseek-v4-pro",
    "ANTHROPIC_DEFAULT_SONNET_MODEL": "deepseek-v4-pro",
    "ANTHROPIC_DEFAULT_HAIKU_MODEL": "deepseek-v4-flash"
  }
}
```

### 3.3 如果你想手动配（preset 不存在或想自定义 1M context）

点 **Custom Provider**，填以下字段：

| 字段 | 值 |
|---|---|
| Name | `DeepSeek V4 (1M context)` |
| ANTHROPIC_BASE_URL | `https://api.deepseek.com/anthropic` |
| ANTHROPIC_AUTH_TOKEN | 你的 DeepSeek API Key |
| ANTHROPIC_MODEL | `deepseek-v4-pro[1m]` |
| ANTHROPIC_DEFAULT_OPUS_MODEL | `deepseek-v4-pro[1m]` |
| ANTHROPIC_DEFAULT_SONNET_MODEL | `deepseek-v4-pro[1m]` |
| ANTHROPIC_DEFAULT_HAIKU_MODEL | `deepseek-v4-flash` |
| CLAUDE_CODE_SUBAGENT_MODEL | `deepseek-v4-flash` |
| CLAUDE_CODE_EFFORT_LEVEL | `max` |

> `[1m]` 后缀**显式启用 1M context**（来自 DeepSeek 官方 `api-docs.deepseek.com/guides/coding_agents`）。
> Haiku 用 Flash（小任务省钱），Opus/Sonnet 用 Pro（主力推理）。

### 3.4 启用切换

在 cc-switch 主界面点这个 provider 的 **Enable** 按钮，或系统托盘里直接点选。

---

## 4. 测试 Claude Code 真的走 DeepSeek 了

**关掉当前所有 Claude Code 会话**，重新打开终端：

```
claude
```

进入对话界面后：

1. 输入 `/status` → 应该看到 `Model: deepseek-v4-pro`（或类似）
2. 随便问一句 `你是谁？`
3. 回答里如果提到 DeepSeek / 杭州 / V4 之类 → ✅ 走对了
4. 如果还在说 "I'm Claude, made by Anthropic" → ❌ 配置没生效，看下面排查

### 排查清单（按顺序）

```bash
# 1. 看环境变量是不是真的设了
echo $ANTHROPIC_BASE_URL          # macOS/Linux
echo %ANTHROPIC_BASE_URL%         # Windows CMD
$env:ANTHROPIC_BASE_URL           # Windows PowerShell
```
应该输出 `https://api.deepseek.com/anthropic`。

```bash
# 2. 看 settings.json 真的被 cc-switch 改了
cat ~/.claude/settings.json       # macOS/Linux
type %USERPROFILE%\.claude\settings.json  # Windows
```
找到 `env` 字段确认 `ANTHROPIC_BASE_URL` / `ANTHROPIC_MODEL` 是否正确。

```bash
# 3. 切完 provider 一定要重启 Claude Code 进程
# Claude Code 启动后才读环境变量，切完不重启不生效
```

---

## 5. 加载团队统一的 .claude.json / settings.json 模板

### 5.1 这两个文件干啥用

| 文件 | 位置 | 作用 |
|---|---|---|
| `~/.claude/settings.json` | 用户级 | 默认权限、hooks、env、MCP 服务器列表 |
| `~/.claude.json` | 用户级 | 会话历史、项目记录、登录态等运行时数据 |

> **注意**：`.claude.json` 含会话记忆，**不要直接覆盖**，否则丢历史。
> 我们只发模板（`.claude.json.template`），让你**手动 merge 关键字段**。

### 5.2 从 VPS 下载团队模板

```bash
# macOS / Linux
curl -fsSL https://files.uuhfn.cloud/team-config/settings.json -o ~/.claude/settings.team.json
curl -fsSL https://files.uuhfn.cloud/team-config/.claude.json.template -o ~/.claude.json.team.template
```

```powershell
# Windows PowerShell
Invoke-WebRequest https://files.uuhfn.cloud/team-config/settings.json -OutFile "$env:USERPROFILE\.claude\settings.team.json"
Invoke-WebRequest https://files.uuhfn.cloud/team-config/.claude.json.template -OutFile "$env:USERPROFILE\.claude.json.team.template"
```

### 5.3 合并到本地（关键步骤）

**`settings.team.json` 怎么合并：**

打开本地 `~/.claude/settings.json` 和团队 `~/.claude/settings.team.json`，把这些字段**从团队模板拷过去**：

- `hooks` — 团队统一的钩子（pre-tool / post-tool / session-start 等）
- `permissions.allow` — 团队认可的默认权限
- `mcpServers` — 团队推荐的 MCP 服务器列表（context7、exa、memory 等）
- `env` — **除了 `ANTHROPIC_AUTH_TOKEN`**（这个是你自己的 key，不要被覆盖）

**保留你自己的字段**：
- `env.ANTHROPIC_AUTH_TOKEN`（你的 DeepSeek API Key）
- `theme` / `editor` 个人偏好
- 任何带 `personal` / `local` 字样的字段

### 5.4 验证合并结果

```bash
claude --version
claude /doctor              # Claude Code 自带健康检查
```

应该输出无错。如果报某个 hook 文件找不到 → 你需要按团队 hook 路径要求把对应脚本也拉下来。

---

## 6. 切回 Claude 官方 / 切其他厂商

cc-switch 的核心价值就是**一键切**：

| 操作 | 方法 |
|---|---|
| 切回 Claude 官方 | cc-switch 选 **Claude (Official)** provider → Enable |
| 切到 Kimi / GLM / Qwen | 选对应 preset → 填 key → Enable |
| 临时禁用所有第三方 | 系统托盘 → **Disable Current Provider** |

**每次切换后必须重启 Claude Code 进程**（关掉所有 `claude` 终端再重开）。

---

## 7. 常见问题

### Q1: `claude` 命令报 `401 Unauthorized` / `Invalid API Key`

- DeepSeek API Key 复制错了（少字符 / 多空格）
- 余额不足，去 https://platform.deepseek.com/usage 充值

### Q2: 回答里说 "I'm Claude, made by Anthropic"

- 没重启 Claude Code 进程，环境变量未生效
- cc-switch 切完没点 **Enable**
- 你在某个项目目录下，项目级 `.claude/settings.local.json` 覆盖了用户级配置

### Q3: 长上下文报错 `context length exceeded`

- 模型 ID 没带 `[1m]` 后缀。检查 cc-switch 里 `ANTHROPIC_MODEL` 是否是 `deepseek-v4-pro[1m]`

### Q4: 想看真实请求是不是发到了 DeepSeek

```bash
# Linux/macOS: 看 Claude Code debug 日志
claude --debug 2>&1 | grep -i "api.deepseek"
```

应看到 `https://api.deepseek.com/anthropic/v1/messages` 之类的请求。

### Q5: cc-switch 改 settings.json 后 Claude Code 没反应

- 关掉所有 Claude Code 终端，**完全重开**（不是新建 tab，是退出进程）
- 如果还不行，手动检查 `~/.claude/settings.json` 是否真的被改了

---

## 8. 进阶：DeepSeek V4 Pro vs Flash 选择策略

| 任务类型 | 推荐 | 原因 |
|---|---|---|
| 大文件重构 / 复杂推理 | `deepseek-v4-pro[1m]` | 1.6T 参数，能啃下整个仓库 |
| 简单问答 / 单文件改 | `deepseek-v4-flash` | 便宜 6 倍，速度更快 |
| 后台 subagent | `deepseek-v4-flash` | 数量多，省钱 |
| 启用 thinking 模式 | 任一模型 | 在请求里加 `"thinking": {"type": "enabled"}` |

cc-switch preset 已经按此策略配好：**Opus/Sonnet → Pro，Haiku/Subagent → Flash**。

---

## 9. 信息来源（确保准确）

本文档信息来自：

- **DeepSeek V4 官方发布说明**（2026-04-24）：https://api-docs.deepseek.com/news/news260424
- **DeepSeek Claude Code 集成指南**：https://api-docs.deepseek.com/quick_start/agent_integrations/claude_code
- **cc-switch DeepSeek V4 preset commit**：https://github.com/farion1231/cc-switch/commit/b1f9ce46538fbb822adf227eef265a6c5367a8ff（2026-04-24）
- **Claude Code 环境变量官方文档**：https://code.claude.com/docs/en/env-vars.md

---

## 10. 你不需要知道但可以查的细节

- DeepSeek V4 base_url 还支持 OpenAI 格式（`https://api.deepseek.com`），适合其他不走 Anthropic 协议的工具
- `deepseek-chat` / `deepseek-reasoner` 旧 ID 会在 **2026-07-24 15:59 UTC 退役**，自动 alias 到 V4-Flash
- cc-switch 支持 cloud sync（Dropbox / OneDrive / WebDAV），多机一致

---

**写完日期**：2026-05-19
**适用版本**：cc-switch v3.14.x / Claude Code 2.x / DeepSeek V4
**有问题找谁**：先看第 7 章 FAQ，仍不解 → 群里 @ ZRainbow
