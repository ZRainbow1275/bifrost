# 团队工具：安装 claude-for-legal-ZH（中国法律执业套件）

> 这是律师陈石（CSlawyer1985）基于 Anthropic 官方 claude-for-legal 项目的**中国法本土化版本**，包含 12 个细分业务领域的 Claude Code 插件。本文档教你**通过我们的 VPS（uuhfn.cloud）**完成安装，不需要科学上网。

---

## 一、它包含什么

| 插件名 | 适用场景 |
|---|---|
| `commercial-legal` | 商务合同审查、续签到期追踪 |
| `corporate-legal` | 并购尽调、董事会决议、公司合规申报 |
| `employment-legal` | 劳动合同解除、跨省用工、规章制度 |
| `privacy-legal` | 个保法影响评估、隐私政策审查 |
| `product-legal` | 产品合规、营销广告法审查 |
| `regulatory-legal` | 法规动态监控、监管简报 |
| `ai-governance-legal` | AI 应用算法安全评估、生成式服务合规 |
| `litigation-legal` | 诉讼/仲裁案件管理、构成要件分析、证据三性 |
| `ip-legal` | 商标检索、FTO、侵权警告函、开源许可证合规 |
| `law-student` | 法考备考、IRAC 训练、知识体系搭建 |
| `legal-clinic` | 法律诊所教学全流程 |
| `legal-builder-hub` | 社区法律技能发现、安全审查、白名单管理 |

许可证：Apache-2.0。可商用、可改、可重新分发，**保留版权声明即可**。

---

## 二、前置条件

- 已经按 `VPS-团队工具分发-教程.md` 装好了 **Claude Code**（`claude --version` 能输出版本号）。
- Claude Code 版本 ≥ 2.1.0（支持 `/plugin` 命令）。
- 已经把 npm 镜像切换到了 `https://npm.uuhfn.cloud/`（在你装 Claude Code 时就已经切换好了，无需再操作）。

---

## 三、安装方式（任选其一）

### ✅ 方式 A：从 VPS git 镜像直接 add（推荐，能自动跟随更新）

打开 Claude Code，输入：

```
/plugin marketplace add https://files.uuhfn.cloud/git/claude-for-legal-ZH.git
```

成功后会看到：
```
✓ Added marketplace 'claude-for-legal-zh' (12 plugins)
```

然后安装你需要的插件，比如商务合同审查：

```
/plugin install commercial-legal@claude-for-legal-zh
```

> 之后每天 02:00 VPS 会自动从上游拉取最新版。你想刷新本地 marketplace 时，运行：
> ```
> /plugin marketplace update claude-for-legal-zh
> ```

---

### 方式 B：下载 tarball 离线安装（不依赖 git，适合纯桌面用户）

#### Windows（PowerShell）

```powershell
# 1. 下载 tarball
Invoke-WebRequest `
  -Uri 'https://files.uuhfn.cloud/claude-for-legal-ZH/releases/latest.tar.gz' `
  -OutFile $env:USERPROFILE\Downloads\claude-for-legal-ZH.tar.gz

# 2. 解压（PowerShell 5.1 自带 tar）
mkdir -Force $env:USERPROFILE\.claude-marketplaces | Out-Null
tar -xzf $env:USERPROFILE\Downloads\claude-for-legal-ZH.tar.gz `
    -C $env:USERPROFILE\.claude-marketplaces

# 3. 路径会变成：
#   C:\Users\<你>\.claude-marketplaces\claude-for-legal-ZH\
```

#### macOS / Linux（终端）

```bash
mkdir -p "$HOME/.claude-marketplaces"
curl -fL https://files.uuhfn.cloud/claude-for-legal-ZH/releases/latest.tar.gz \
  | tar -xz -C "$HOME/.claude-marketplaces"
# 解压到：$HOME/.claude-marketplaces/claude-for-legal-ZH/
```

然后在 Claude Code 中：

```
/plugin marketplace add ~/.claude-marketplaces/claude-for-legal-ZH
/plugin install commercial-legal@claude-for-legal-zh
```

> Windows 用户的路径写法：`/plugin marketplace add C:\Users\<你>\.claude-marketplaces\claude-for-legal-ZH`

---

### 方式 C：git clone 后手动 add（适合想看源码的人）

```bash
# 这一步 clone 走的是我们 VPS，不需要翻墙
git clone https://files.uuhfn.cloud/git/claude-for-legal-ZH.git
cd claude-for-legal-ZH

# 在 Claude Code 中：
/plugin marketplace add ./
/plugin install ip-legal@claude-for-legal-zh
```

---

## 四、常用命令清单

| 操作 | 命令 |
|---|---|
| 查看所有已添加的 marketplace | `/plugin marketplace list` |
| 查看 marketplace 里有哪些插件 | `/plugin search @claude-for-legal-zh` |
| 安装单个插件 | `/plugin install <name>@claude-for-legal-zh` |
| 批量安装（推荐律所装这几个） | 见下方 |
| 检查 marketplace 是否有更新 | `/plugin marketplace update claude-for-legal-zh` |
| 卸载插件 | `/plugin uninstall <name>` |
| 卸载整个 marketplace | `/plugin marketplace remove claude-for-legal-zh` |

**律所典型套餐**（建议全员安装）：

```
/plugin install commercial-legal@claude-for-legal-zh
/plugin install corporate-legal@claude-for-legal-zh
/plugin install employment-legal@claude-for-legal-zh
/plugin install litigation-legal@claude-for-legal-zh
/plugin install privacy-legal@claude-for-legal-zh
```

**新业务方向（推荐再加）**：

```
/plugin install ai-governance-legal@claude-for-legal-zh
/plugin install ip-legal@claude-for-legal-zh
```

---

## 五、安装后会发生什么

安装单个插件后，Claude Code 会在 `~/.claude/plugins/claude-for-legal-zh/<plugin-name>/` 下展开：

- `agents/`        子代理（subagent）定义，比如"合同审查员"
- `skills/`        可调用技能，比如"识别民法典适用条款"
- `commands/`      自定义 slash 命令，比如 `/contract-review`
- `hooks/`         钩子脚本（一般不需要管）

启动一次新对话后，输入 `/help` 就能看到新增的 slash 命令。

---

## 六、验证 VPS 链路是否畅通

如果你怀疑装得不对，跑下面这条命令，应该返回 HTTP 200：

```bash
# Windows / macOS / Linux 都可以
curl -I https://files.uuhfn.cloud/claude-for-legal-ZH/releases/latest.tar.gz
```

正常输出包含：
```
HTTP/2 200
content-type: application/gzip
content-length: <几十万>
```

如果想确认 git 镜像也通，跑：

```bash
git ls-remote https://files.uuhfn.cloud/git/claude-for-legal-ZH.git
```

应该返回一行包含 commit SHA 和 `refs/heads/main` 的输出。

---

## 七、出错时的排查

| 症状 | 原因 | 解决 |
|---|---|---|
| `/plugin marketplace add` 提示 `failed to clone` | git 没装，或者 PATH 里找不到 | 装 [Git for Windows](https://git-scm.com/download/win) |
| `git ls-remote` 报 SSL 证书错误 | 时间不对 / 老的根证书库 | Windows: 同步系统时间；老系统：升级 Windows Update |
| 下载 tarball 卡住 | 域名解析问题 | `nslookup files.uuhfn.cloud` 应该解析到我们 VPS IP；如果没有，让管理员检查 DNS |
| `/plugin install` 提示 `marketplace not found` | 还没 add 过 marketplace | 先执行方式 A/B/C 中的 `add` 步骤 |
| 装好了但 `/help` 看不到新命令 | 需要重启 Claude Code | 退出并重新打开新会话 |

遇到无法解决的问题，把报错截图发给 ZRainbow。

---

## 八、隐私与安全说明

- 所有插件源代码在你本地 `~/.claude/plugins/` 下可见，**不会调用任何境外服务**——它们只是 prompt 和 skill 的组合。
- 实际的 AI 推理走你在 cc-switch 中配置的服务商（DeepSeek / Anthropic 等），与本仓库无关。
- 律所内部敏感数据是否经过 LLM，取决于你**在 Claude Code 里输入了什么**，与插件本身无关。
- Apache-2.0 协议要求：如果你二次分发或修改后再分发，必须保留 LICENSE 和 NOTICE 文件。仅自用、内部使用**没有任何限制**。

---

**作者**：ZRainbow（浙江海泰律师事务所）
**最后更新**：2026-05-19
