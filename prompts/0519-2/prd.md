# PRD — Server B 内部 Claude artifacts marketplace + visual panel

> **Task**: `.trellis/tasks/05-19-server-b-claude-artifacts-marketplace-visual-panel`
> **Owner**: ZRainbow
> **Status**: planning (P9 synthesis — 等用户回答 Open Questions 后转 spec.md)
> **Created**: 2026-05-19
> **Composes**: `05-19-server-b-private-distribution`（distribution 栈底座）、`05-19-0519-1-improvement`（PR-3 后续改进）

---

## Goal

把 Anthropic 在 *"Claude Code at Scale"* 文章中提出的 **"agent manager + managed marketplace + plugin = 团队级 Claude 能力分发单元"** 范式，**落地到 Bifrost 现有 Server A / Server B 双机架构**。具体做法：

1. **复用** Server B 已经在 `0519-1` 中交付的私有分发栈（Caddy `/var/lib/dist/` 静态、Caddy `:8082` git smart-HTTP、Verdaccio `:4873`），把它升级成"团队 Claude Code 插件分发源"。
2. **不重新发明轮子** — Claude Code 原生已支持 `/plugin marketplace add <git-url | https://.../marketplace.json>`，marketplace 协议就是 git 仓库 + `.claude-plugin/marketplace.json` 静态清单；**用户希望的"可视化面板"实际是 Claude Code 内置 TUI `/plugin`**，我们不重新写 UI，把"web 面板"作为 nice-to-have 放在 PR-5（可延后或砍掉）。
3. **零新增公网端口** — 全量复用 `0519-1` 已经通过 `files.uuhfn.cloud` + Caddy `@git path /git/*` 暴露的反代链路（A→wg→B），只新增 path matcher 和 systemd timer，不动 nftables / WG 拓扑。
4. **可治理性优先** — 对齐 Anthropic 文章"approved skills / required code review / limited initial access"理念，引入 `team .claude/settings.json` 模板（`extraKnownMarketplaces` + `enabledPlugins` 集中下发）和 `permissions.deny` 白名单。

一句话：**把 Server B 升级成一个团队级 Claude Code 插件 / skill / hook / MCP 配置的"App Store"，团队成员通过 `/plugin marketplace add bifrost-internal` 一行命令接入，所有分发动作走现有 `files.uuhfn.cloud` 反代链路，不引入新的公网攻击面。**

---

## Naming（待用户选择 — 注意避开 reserved names）

Anthropic 保留：`claude-plugins-official`、`anthropic-marketplace`、`claude-code-marketplace`。**禁止使用**。

候选 marketplace name（用户三选一）：

| 候选 | 含义 | 建议 |
|---|---|---|
| `bifrost-internal` | 与项目代号一致，强调"内部" | 推荐：与 `bifrost-api` / `scripts/server-*.sh` 同源命名 |
| `uuhfn-team` | 与团队域名 `uuhfn.cloud` 一致 | 强调"团队"，对外（如未来开源/借用）含义清晰 |
| `creator-five` | 与仓库代号一致 | 不推荐，外人难以理解，且 CodeNexus 项目名易混 |

**P9 推荐**：`bifrost-internal` —— 跟项目代号一致，可与 `bifrost-api` 形成"控制面 + 分发面"对称命名。

对应 URL 形态：

```
git+https://files.uuhfn.cloud/git/bifrost-internal.git
       └─→ A:443 →(reverse_proxy)→ B:wg0:8082 →(fcgiwrap)→ git-http-backend
              └─→ /var/lib/git-mirrors/bifrost-internal.git
```

或者纯静态形态（不走 git，纯 https 拉 marketplace.json + tarball）：

```
https://files.uuhfn.cloud/plugins/marketplace.json
https://files.uuhfn.cloud/plugins/<plugin-name>/<version>.tar.gz
       └─→ A:443 →(reverse_proxy)→ B:wg0:8081 →(file_server)→ /var/lib/dist/plugins/
```

→ 实际方案在 ADR-1 中决策（同时支持两种，**git 模式为主**）。

---

## Architecture

### 顶层拓扑

```
                Internet
                   │
                   ▼
       ┌───────────────────────┐
       │  Server A (uuhfn.cloud)│
       │  Caddy + TLS terminate │
       │                        │
       │  files.uuhfn.cloud {   │
       │    @plugins path /plugins/*                    ─┐
       │    handle @plugins → reverse_proxy 10.8.0.2:8081│ NEW path matcher
       │    @git path /git/*                              │
       │    handle @git     → reverse_proxy 10.8.0.2:8082│ (existing 0519-1)
       │    handle (default)→ reverse_proxy 10.8.0.2:8081│
       │  }                                              ─┘
       └────────────┬───────────────────────────────────┘
                    │ wg0 / 10.8.0.0/24 (encrypted tunnel)
                    ▼
       ┌────────────────────────────────────────────┐
       │  Server B (10.8.0.2, vpn-first)            │
       │                                            │
       │  Caddy on wg0:8081  (file_server browse)   │
       │    /var/lib/dist/                          │
       │      ├── plugins/                  ◀── NEW │
       │      │    ├── marketplace.json            │
       │      │    ├── hello-world-skill/          │
       │      │    │    └── releases/              │
       │      │    └── ...                         │
       │      └── releases/  (existing)            │
       │                                            │
       │  Caddy on wg0:8082  (git smart-HTTP RO)   │
       │    /var/lib/git-mirrors/                  │
       │      ├── claude-for-legal-zh.git  (existing)│
       │      └── bifrost-internal.git    ◀── NEW  │
       │                                            │
       │  systemd timer:                            │
       │    git-mirror@bifrost-internal.timer  ◀ NEW│
       │      (sync upstream curated plugins +     │
       │       internal-only plugins via push)     │
       └────────────────────────────────────────────┘

       Team laptops
       ──────────────
       1. /plugin marketplace add git+https://files.uuhfn.cloud/git/bifrost-internal.git
       2. /plugin browse                     (built-in TUI panel)
       3. /plugin install hello-world-skill  (lands in ~/.claude/plugins/cache/)

       Onboarding (new joiner, before login):
       export CLAUDE_CODE_PLUGIN_SEED_DIR=$HOME/.claude/seed
       curl -fsSL https://files.uuhfn.cloud/seed/bifrost-internal.tar.gz | tar -xz -C ...
```

### 每个 plugin source 类型的取舍

Claude Code marketplace 协议支持 5 种 `source.type`：`github` / `url` / `git-subdir` / `npm` / `path`（local）。本架构混用如下：

| source.type | 用于什么场景 | 路径 | 备注 |
|---|---|---|---|
| `git-subdir` | **monorepo 模式**：单个 `bifrost-internal.git` 仓库，下面 `plugins/<name>/` 子目录就是一个插件 | `git+https://files.uuhfn.cloud/git/bifrost-internal.git` + `path: plugins/<name>` | **推荐为主路径**（见 ADR-1）：审批合一、tag 统一、监控统一 |
| `npm` | 团队内部 npm 库已经存在 → 复用 Verdaccio 分发 plugin | `registry: https://npm.uuhfn.cloud/` | 备用：如果某个 plugin 也是个 npm 包（如 `@bifrost/claude-skill-foo`），可双轨发布 |
| `url` | 直接拉单个 tarball（无需 git） | `https://files.uuhfn.cloud/plugins/<name>/<ver>.tar.gz` | 应急通道：紧急回滚旧版本时直接静态分发 |
| `path` | 本地 dev 调试 | `$HOME/.claude/seed/<plugin>` | 仅开发者本地，不在分发链路 |

### 团队 settings 集中下发

为了让"`/plugin marketplace add bifrost-internal`"成为**默认开箱可用**（团队成员无需手动 `marketplace add`），分发一份 team-level `.claude/settings.json` 模板：

```json
{
  "extraKnownMarketplaces": {
    "bifrost-internal": {
      "source": {
        "type": "url",
        "url": "git+https://files.uuhfn.cloud/git/bifrost-internal.git"
      }
    }
  },
  "enabledPlugins": {
    "bifrost-internal/hello-world-skill": true,
    "bifrost-internal/code-review-pack": true
  },
  "permissions": {
    "deny": [
      "Bash(rm -rf /*)",
      "Bash(curl http://*)"
    ]
  }
}
```

**分发载体**：
- 已加入团队的开发机：放到项目仓库 `.claude/settings.json` 即可（per-project）
- 新成员 onboarding：`CLAUDE_CODE_PLUGIN_SEED_DIR` 指向 `https://files.uuhfn.cloud/seed/` 下载的 tarball 解压目录

---

## Strategic Expansion（DIVERGE）

### 1. 未来演进可能

- **多 marketplace 矩阵**：`bifrost-internal`（公司全员）→ `bifrost-internal-legal`（法务团队专用 plugin，含合规 skill）→ `bifrost-internal-ops`（运维 hook + diagnostics MCP）。每个 marketplace 独立 git 仓库，独立 audit log。
- **upstream mirror**：把 Anthropic 官方 `anthropic-marketplace` 镜像到 `bifrost-internal-upstream`（**只读、curate-only**），团队成员国内访问 upstream 时无需访问 github.com，由 git-mirror systemd timer 定期 sync。
- **审批 workflow**：基于 git push hook，在 `marketplace.json` 接收 PR 时强制 lint（schema validation + permissions denylist 校验），合并即发布。bifrost-api 提供 `/marketplace/pending` 可视化审批界面。
- **使用率遥测**：可选 hook 收集"哪些 plugin 在被使用、谁在用"（**隐私敏感、纯统计**），bifrost-api 出 dashboard 给 agent manager 做"哪些 plugin 该 deprecate"决策依据。

### 2. 相关并行场景

- **`05-19-server-b-private-distribution`**：本任务的物理底座 — Caddy `:8081/:8082`、git-mirror systemd template、fcgiwrap、`/var/lib/dist/`、`/var/lib/git-mirrors/`，都已在 0519-1 落地。本任务**只新增 path/template/slug**，**不改动现有 distribution 步骤的实现**。
- **`05-19-server-a-hardening-v2` PR-3**：本任务复用 A 端 `internal` TLS / vpn-first / `bind` 已经稳定的反代链路，不引入新的 A 端表面。
- **`05-18-newapi-uuhfn-cloud-package`**：与 NewAPI 完全解耦。NewAPI 是 LLM 网关，marketplace 是 Claude Code 客户端能力分发，两条链路平行。
- **claude-for-legal-ZH mirror**：现有 `git-mirror@claude-for-legal-zh.service` 是 systemd template 实例，添加 `bifrost-internal` 只需加 case arm + service 实例（无需新写脚本）。

### 3. 失败 / 边界场景

- **marketplace.json schema 漂移**：Anthropic 更新 marketplace 协议 → 老的 marketplace.json 不被新 Claude Code 识别。缓解：bifrost-api `/marketplace/validate` 用最新 JSON Schema 校验；CI 在合并 PR 前跑同样校验。
- **`/plugin install` 在 LAN 外失败**：因为 `files.uuhfn.cloud` 只在 LAN-only / VPN-only 可达 → 出差成员需先连 VPN（与现有 `npm.uuhfn.cloud` 行为完全一致，团队已习惯）。**这不是 bug，是设计**。
- **plugin 版本回退**：用户安装了一个有 bug 的 v0.3.0 想回 v0.2.0。git-subdir 模式靠 `version` 字段 + git tag；如果 marketplace.json 只指 `main` 分支无固定 tag，则没法回退。**强制 plugin 用 semver git tag** 作为 acceptance criterion。
- **恶意 plugin 提权**：plugin 的 hooks 可以执行任意 shell。缓解：(1) `permissions.deny` 在 settings 层 hard-block 危险命令；(2) PR review required；(3) bifrost-api `/marketplace/audit` 给 agent manager 看每个 plugin 的 hook 内容 diff。
- **air-gapped 团队成员**：用 `CLAUDE_CODE_PLUGIN_SEED_DIR` 从 `files.uuhfn.cloud/seed/bifrost-internal.tar.gz` 离线 bootstrap。
- **upstream sync 失败**：如果 Q3 选 `mirror upstream`，github.com 不可达时 sync 失败 → 用 `systemctl status git-mirror@bifrost-internal-upstream` 探活，bifrost-api `/marketplace/status` 暴露最近同步时间。

---

## Open Questions（待用户决策）

> 标 ★ = 阻塞 implement 阶段，必须先回答。其余可在 PR-N 之前回答即可。

| # | 议题 | 选项 | 推荐 | 阻塞 |
|---|---|---|---|---|
| **Q1** | marketplace 命名 | A) `bifrost-internal` / B) `uuhfn-team` / C) `creator-five` / D) 其他 | A | ★ |
| **Q2** | plugin 仓库结构 | A) monorepo + `git-subdir`（推荐） / B) N 个独立 plugin 仓库 / C) 混合 | A | ★ |
| **Q3** | 是否镜像官方 marketplace | A) 不镜像，only curate-internal / B) 镜像 + curate / C) 镜像 only | A（先纯内部，未来加 B） | |
| **Q4** | 可视化面板形态 | A) 完全依赖 `/plugin` CLI TUI（minimal） / B) `/plugin` + bifrost-api 只读 dashboard（admin-gated） / C) 完整 web admin（browse / approve / upload） | B | ★ |
| **Q5** | 鉴权模型 | A) LAN-only 公开读（与现有 `npm.uuhfn.cloud` 一致） / B) `htpasswd` / C) Bearer token | A | |
| **Q6** | 版本 / 发布约定 | A) 强制 semver git tag + auto-release tarball / B) main 分支 floating / C) 双轨 | A | |
| **Q7** | 新成员 onboarding | A) 项目仓库 commit `.claude/settings.json` / B) `CLAUDE_CODE_PLUGIN_SEED_DIR` + seed tarball / C) 两者都做 | C | |

**最关键的 3 个问题**（决定 PR-N 是否能并行启动）：

1. **Q1（命名）** — 影响所有 git remote / Caddy path / systemd service 名，**必须先确定**。
2. **Q2（仓库结构）** — monorepo 还是多仓库决定了 git-mirror systemd 是 1 个实例还是 N 个实例，影响 PR-2 的脚本结构。
3. **Q4（面板形态）** — 决定是否需要 PR-5（web admin dashboard），如果 B 则 PR-4 只读 dashboard 即可结题，PR-5 可砍。

---

## Requirements

### 功能性

- **R1**: 团队成员在已加入 wg / 在公网走 `files.uuhfn.cloud` 的状态下，执行 `/plugin marketplace add git+https://files.uuhfn.cloud/git/<marketplace-name>.git` 必须成功。
- **R2**: 该 marketplace 下至少有 **1 个 sample plugin**（PR-1 交付），团队成员 `/plugin install <name>` 后能在 `~/.claude/plugins/cache/<marketplace>/<plugin>/<version>/` 看到文件落盘。
- **R3**: 团队成员安装后，重新打开 Claude Code 应能识别 plugin 提供的 skill / hook / MCP；若 plugin 含 skill，`/skill list` 应能列出该 skill。
- **R4**: 提供 team-level `.claude/settings.json` 模板，集中下发 `extraKnownMarketplaces` + `enabledPlugins` + `permissions.deny`，新机器（无任何手动配置）只要拉到这份 settings + 网络 OK 就能开箱可用。
- **R5**: bifrost-api 新增 `/marketplace/*` 只读 admin-gated endpoints，至少包含：
  - `GET /marketplace/list` — 列出所有可分发的 plugin（解析 marketplace.json）
  - `GET /marketplace/status` — 最近 sync 时间、git latest commit、磁盘占用、HTTP 探活
  - `GET /marketplace/logs?service=git-mirror-bifrost-internal` — 最近 200 行 systemd 日志
- **R6**: 如果 Q3 选 mirror upstream，systemd timer `git-mirror@bifrost-internal-upstream.timer` 每 6 小时同步 upstream marketplace 仓库，sync 失败有 alert（journalctl + bifrost-api `/marketplace/status` 暴露）。

### 非功能性 / 安全

- **R7**: **零新增公网端口**（与 `0519-1` 同款 nftables 配置兼容，不动 `iifname "wg0"` 白名单矩阵）。
- **R8**: bifrost-api `/marketplace/*` 路由全部 `Depends(require_admin)`，与 `/mirrors/*` 一致。
- **R9**: marketplace.json 在 PR 合并前由 CI 跑 JSON Schema 校验（schema 来源：Anthropic 官方文档 + 本地 cached copy）。
- **R10**: `permissions.deny` 模板必须 deny `Bash(curl http://*)`、`Bash(wget http://*)`（plain HTTP），`Bash(rm -rf /*)` 等高危操作。
- **R11**: marketplace 仓库 + plugins 子目录必须用 semver git tag 标版本（如 `hello-world-skill/v0.1.0`），禁止 floating main。

### 可观测性

- **R12**: `gitnexus_impact / gitnexus_detect_changes` 在 implement 阶段被使用（对齐 `CLAUDE.md` 项目约定）。
- **R13**: `tests/test-in-docker.sh` parity check 必须能 cover 新增 path matcher 和 systemd unit template。

---

## Acceptance Criteria

- [ ] **AC-1**: `git ls-remote https://files.uuhfn.cloud/git/bifrost-internal.git` 在团队成员机器（WG / LAN-only）上返回 ref 列表。
- [ ] **AC-2**: `curl -fsSL https://files.uuhfn.cloud/plugins/marketplace.json | jq .name` 返回 `"bifrost-internal"`（或 Q1 决议名）。
- [ ] **AC-3**: 全新团队成员笔记本：`/plugin marketplace add git+https://files.uuhfn.cloud/git/bifrost-internal.git` → `/plugin browse` → 看到至少 1 个 plugin → `/plugin install hello-world-skill` → 文件落在 `~/.claude/plugins/cache/bifrost-internal/hello-world-skill/<version>/`。
- [ ] **AC-4**: `nmap -p- <SERVER_B_PUBLIC_IP>` 输出与 `0519-1` 完全一致（22/tcp + 51820/udp，其他全 closed/filtered，**无新增端口**）。
- [ ] **AC-5**: `bash scripts/server-b.sh --enable-distribution` 跑两次都成功，第二次秒级（idempotent step machine 不重做已完成步骤）。
- [ ] **AC-6**: `systemctl status git-mirror@bifrost-internal.timer` 显示 active + 最近一次 OnCalendar 触发时间。如果 Q3 选 mirror，`git-mirror@bifrost-internal-upstream.timer` 同上。
- [ ] **AC-7**: `curl -u admin:<token> https://api.uuhfn.cloud/marketplace/status | jq .` 返回 JSON，含字段 `last_sync_ts / disk_used / latest_commit / http_probe`。`/marketplace/list` 返回 plugin 数组。
- [ ] **AC-8**: 团队 `.claude/settings.json` 模板被 commit 到 `prompts/0519-1/team-config/`（脱敏版本），文档说明放在 `docs/USAGE.md` 新增章节。`permissions.deny` 至少包含 4 条高危规则。
- [ ] **AC-9**: 一个 plugin 的版本回退测试：将 `hello-world-skill` 发 `v0.1.0` 和 `v0.2.0`，团队成员 `/plugin install hello-world-skill@v0.1.0` 应成功落到对应版本目录。
- [ ] **AC-10**: `docs/SECURITY.md` 新增 `### Server B 内部 Claude marketplace 安全边界` 章节，说明：分发链路 / 鉴权矩阵 / `permissions.deny` 设计 / plugin 审批 SOP。

---

## PR Split Plan

> 总体 ≤ 6 PR，每个 ≤ 800 LOC。PR-5 可砍（取决于 Q4）。

### PR-1: 静态 marketplace 骨架 + sample plugin

**Scope**:
- `prompts/0519-1/marketplace-bootstrap/` 新建目录，包含：
  - `marketplace.json`（顶层 marketplace 清单，schema-validated）
  - `plugins/hello-world-skill/`（1 个 sample plugin：1 个 skill + README）
  - `plugins/hello-world-skill/.claude-plugin/plugin.json`
  - `plugins/hello-world-skill/skills/hello/SKILL.md`
- `scripts/validate-marketplace.sh`（CI 用，跑 JSON Schema 校验，约 80 行）
- 不动 server-b.sh，不动 Caddy。**纯 artifact**。

**Dependencies**: 无。可立即启动。

**Exit Criteria**:
- 本地 `scripts/validate-marketplace.sh prompts/0519-1/marketplace-bootstrap/` 通过
- README 说明如何把这堆文件 push 到 Server B 上的 `bifrost-internal.git` 裸仓库 + `/var/lib/dist/plugins/`

**LOC**: ~200~300。

---

### PR-2: server-b.sh `--enable-marketplace` 步骤 + Caddy path matcher

**Scope**:
- `scripts/server-b.sh:2558` `enable_distribution()` 内**新增** step `07_render_marketplace`（在 06 之后、08 之前），调用：
  - `_distribution_prepare_marketplace_dirs`（mkdir `/var/lib/dist/plugins/`、`/var/lib/git-mirrors/bifrost-internal.git`）
  - `_distribution_init_marketplace_git`（`git init --bare` if 不存在 + seed marketplace.json）
- `configs/caddy/Caddyfile-b-distribution.tpl:10` 在 `:8081` site 内新增（紧接 `root * /var/lib/dist` 之前/之后均可）：
  - `handle_path /plugins/* { root * /var/lib/dist/plugins; file_server; }` —— 显式 matcher，便于未来加 header / cache 策略
  - 注：因为 `/var/lib/dist/plugins/` 已是 root 下子目录，此 path matcher **不是必需**，但**强烈推荐**用来加 Cache-Control / ETag header 和分离访问日志
- `scripts/server-b.sh` 内 `_distribution_apply_docker_user_rules` 无需改动（marketplace 不引入新 docker）
- `scripts/bifrost-readonly-router.sh` 新增 case arm：`logs:git-mirror-bifrost-internal` / `marketplace:stat`（disk + git latest commit）

**Dependencies**: PR-1（需要 marketplace.json 内容样本）

**Exit Criteria**:
- 本地 docker parity（`tests/test-in-docker.sh`）通过
- `bash scripts/server-b.sh --enable-distribution` 在干净 VM 上跑出新 step `07_render_marketplace`，再跑一次秒级跳过

**LOC**: ~250~350。

---

### PR-3: Server A Caddyfile `@plugins` matcher + git mirror systemd 实例

**Scope**:
- `configs/caddy/Caddyfile-a.tpl:276-286` `files.{{DOMAIN}}` 块内**新增** `@plugins path /plugins/*` 显式 matcher（可选，因为 default handle 已经 proxy 到 8081；显式加是为了未来在 A 端加 cache / rate-limit）
- `scripts/server-a.sh` 内同步加 inline Caddyfile 渲染分支（与 .tpl 保持 parity）
- `scripts/server-b.sh` 内 `_distribution_render_systemd_units` 内新增 case：当 marketplace 启用时，`systemctl enable --now git-mirror@bifrost-internal.timer`
  - timer 走与 `claude-for-legal-zh` 同款 systemd template（**无需新写 unit 文件**）
  - OnCalendar 默认每 30 分钟（plugin 更新频率低于代码仓库）
- 如果 Q3 = mirror upstream，再加 `git-mirror@bifrost-internal-upstream.timer`
- 修改 `scripts/git-mirror-sync.sh` 让它支持 marketplace 仓库（如果有差异；初步预计可直接复用）

**Dependencies**: PR-2

**Exit Criteria**:
- `nmap` 输出与 baseline 一致（**无新端口**）
- `systemctl list-timers | grep git-mirror` 含新 instance
- `curl -I https://files.uuhfn.cloud/plugins/marketplace.json` 返回 200，`Cache-Control` header 符合预期

**LOC**: ~150~250。

---

### PR-4: bifrost-api `/marketplace/*` 只读 admin-gated routes

**Scope**:
- `bifrost-api/app/routers/marketplace.py` 新建（**复用 `routers/mirrors.py` 的所有 helper**，包括 `_run_readonly_command`、`_probe_http`、`require_admin`）
- `bifrost-api/app/main.py:128` 后新增 `app.include_router(marketplace_router.router)`
- 4 个 endpoint：
  - `GET /marketplace/list` → 解析 `/var/lib/dist/plugins/marketplace.json`（through SSH readonly cat）→ 返回 plugin 数组
  - `GET /marketplace/status` → 复合：`disk:report` + `wg:age` + git `latest-commit` + `_probe_http(https://10.8.0.2:8081/plugins/marketplace.json)`
  - `GET /marketplace/logs?service=git-mirror-bifrost-internal` → 走 readonly-router `logs:git-mirror-bifrost-internal`
  - `GET /marketplace/probe` → 单独的 HTTP 探活（轻量，频率高）
- `bifrost-api/app/config.py` 无需改动（复用 `server_b_wg_ip` / `readonly_*` 已有字段）
- `scripts/bifrost-readonly-router.sh` 在 PR-2 已加的 case arm 基础上完善

**Dependencies**: PR-2, PR-3

**Exit Criteria**:
- pytest 新增 `tests/test_marketplace_router.py`（mock SSH + HTTP，约 100 行）
- 端到端：在 A 上 `curl -u admin:<pwd> https://api.uuhfn.cloud/marketplace/status` 返回完整 JSON

**LOC**: ~300~400（router ~200 + tests ~100~150）。

---

### PR-5（可选）: 简易 web admin dashboard

**Scope**：
- 仅在 Q4 = C 时启动
- `bifrost-api/app/routers/marketplace.py` 加入 HTML 渲染端点 `/marketplace/dashboard`（StaticFiles + 简单 Jinja2 模板）
- 功能限于"浏览 + 查看 plugin metadata"，**不做 upload / approve**（upload 走 git PR workflow，更安全）
- 复用 `register_page_router` 的 admin auth pattern

**Dependencies**: PR-4

**Exit Criteria**:
- 浏览器访问 `https://api.uuhfn.cloud/marketplace/dashboard` 显示 plugin 列表 + 最近 sync 时间 + 磁盘用量

**LOC**: ~400~500（含 HTML/CSS/JS）。

**P9 建议**：除非 Q4 明确选 C，**否则砍掉此 PR**。`/plugin` 内置 TUI 已经覆盖团队成员的"browse / install" 90% 需求，agent manager 的 "approve" 走 git PR review 比 web 表单更安全更可审计。

---

### PR-6: 团队 settings 模板 + onboarding seed + 文档

**Scope**:
- `prompts/0519-1/team-config/.claude/settings.json.template`（脱敏）
- `prompts/0519-1/team-config/CLAUDE.md.template`（团队级 CLAUDE.md，含 `permissions.deny` 注释、marketplace 使用说明）
- `prompts/0519-1/marketplace-bootstrap/seed/bifrost-internal-seed.tar.gz` 生成脚本（`scripts/build-marketplace-seed.sh`，约 50 行）
- `docs/USAGE.md:589` 后续新增章节 `### Server B 内部 Claude marketplace`（团队成员快速接入指南、设置 `CLAUDE_CODE_PLUGIN_SEED_DIR` 步骤、版本回退操作）
- `docs/SECURITY.md:97` 后续新增 `### Server B 内部 Claude marketplace 安全边界`（鉴权矩阵 + `permissions.deny` 设计 + plugin 审批 SOP + 恶意 plugin 缓解）

**Dependencies**: PR-1..PR-4

**Exit Criteria**:
- 一个新成员只读着 `docs/USAGE.md` 新章节，10 分钟内能从干净笔记本完成 `/plugin install hello-world-skill`
- `docs/SECURITY.md` 的鉴权矩阵 + nftables 矩阵与 implement 完全一致

**LOC**: ~200~400（绝大部分是 doc）。

---

### PR 依赖图

```
PR-1 (artifact)
  └─→ PR-2 (server-b.sh + B Caddy)
        └─→ PR-3 (A Caddy + systemd timer)
              └─→ PR-4 (bifrost-api /marketplace/*)
                    ├─→ PR-5 (web dashboard, OPTIONAL)
                    └─→ PR-6 (team config + docs)
```

**估算**：PR-1..PR-4 + PR-6 = 5 个 PR，每个 1~2 个工作日，**总计 5~10 工作日**（不含 review/iteration）。

---

## Risk Register

| # | 风险 | 概率 | 影响 | 缓解 |
|---|---|---|---|---|
| RK-1 | Anthropic 升级 marketplace 协议导致老 marketplace.json 不被新 Claude Code 识别 | 中 | 高 | (1) 在 CI 加 schema validation；(2) `docs/USAGE.md` 标注 minimum Claude Code 版本；(3) 监控 Anthropic changelog（agent manager 责任） |
| RK-2 | 团队成员安装了恶意 / 写错的 plugin 触发 destructive hook | 低 | 极高 | (1) `permissions.deny` 兜底；(2) plugin 进 marketplace 强制 PR review；(3) bifrost-api `/marketplace/audit` 显示 hook diff |
| RK-3 | `git-mirror@bifrost-internal-upstream` sync 失败（github.com 国内不可达）→ 团队拿不到 upstream 更新 | 中 | 中 | (1) 仅当 Q3=mirror 才有此风险；(2) bifrost-api `/marketplace/status` 暴露 `last_sync_ok`；(3) restic 备份保留最后一次 successful snapshot |
| RK-4 | `/plugin install` 在公网（无 VPN）失败导致出差成员阻塞 | 高 | 低 | (1) **是设计**，对齐现有 `npm.uuhfn.cloud` 一致；(2) 文档明示"需 VPN 或 LAN"；(3) onboarding tarball seed 离线模式 |
| RK-5 | plugin 没打 git tag → 团队成员无法 pin 版本，回退困难 | 中 | 中 | (1) R11 强制 semver tag；(2) PR review checklist 含"是否打了 tag"；(3) `scripts/validate-marketplace.sh` 检查 `version` 字段与 git tag 对应 |
| RK-6 | `/var/lib/dist/plugins/` 磁盘膨胀（大量 binary skill assets） | 低 | 中 | (1) `bifrost-readonly-router.sh` `disk:report` 暴露用量；(2) bifrost-api `/marketplace/status` 触发 alert（>80%）；(3) restic 备份策略加 prune |
| RK-7 | 与 `05-19-server-a-hardening-v2` PR-3 合并冲突（同改 `Caddyfile-a.tpl`） | 中 | 低 | 等 PR-3 合入 main 后再启动本任务 PR-3。或主动 rebase。 |
| RK-8 | bifrost-api 跨 wg 调用 B 端 `cat marketplace.json` 因 wg 抖动失败 | 低 | 低 | 复用 `mirrors_router.py` 已有的 timeout + 503 error handling pattern |
| RK-9 | 团队 `.claude/settings.json` 模板被错误覆盖导致 `permissions.deny` 失效 | 低 | 高 | (1) seed tarball + git 历史可恢复；(2) docs/SECURITY.md 明示"`permissions.deny` 是 hard rule，禁止本地覆盖"；(3) 未来加 settings checksum verification hook |

---

## Out of Scope

- **不**做 plugin 内容（除了 1 个 sample `hello-world-skill`）。team 的实际 plugin 创作是后续任务。
- **不**做 plugin 自动审批 / CI/CD（push hook 触发 systemd timer 同步即可，复杂审批走 git PR review）。
- **不**镜像 npm-based plugin（已经在 Verdaccio，不重复造轮子）。
- **不**做"upload via web UI"（PR-5 即使做了也只 browse，upload 走 git）。
- **不**对 Anthropic 官方 `anthropic-marketplace` 做 fork（只在 Q3=mirror 时做单向 read-only mirror）。
- **不**改动 Verdaccio / NewAPI / claude-for-legal-zh 任何现有服务。
- **不**改动 wg / nftables 拓扑（**零端口变更**）。
- **不**做 plugin 使用率遥测（隐私风险，留给未来任务）。
- **不**做 multi-tenant marketplace（一个团队一个 marketplace，未来扩展再说）。

---

## Decision (ADR-lite)

### ADR-1 — Plugin 仓库结构 = monorepo `git-subdir`  [2026-05-19, LOCKED via Q2=A]

**Context**：Claude Code marketplace 支持 `git-subdir`（一个 git 仓库下多个 plugin 子目录）和"N 个独立 plugin 仓库 + N 个 source 条目"两种模式。本项目当前只有 1 个 git-mirror systemd template（`git-mirror@.service`），加一个 instance 比加 N 个简单 N 倍。

**Decision**：**monorepo + `git-subdir`**。一个 `bifrost-internal.git` 仓库，下面 `plugins/<name>/` 是每个 plugin；marketplace.json 用 `git-subdir` source type 引用每个子目录。

**Consequences**：
- 单仓库 → 单 git-mirror systemd instance → 部署 / 监控 / 备份成本最低
- 单仓库 → 单 PR review entry point → 审批 SOP 统一
- 单仓库 → 一次性能看到所有 plugin 历史 → agent manager 更容易做 deprecation 决策
- 缺点：plugin 之间没法独立打 tag（必须用 `plugins/<name>/v0.1.0` 格式 git tag）→ R11 强制 enforce
- 缺点：一个 plugin 损坏可能影响整个仓库 clone（小概率，git 本身能容忍）

### ADR-2 — 可视化面板 = `/plugin` TUI（团队成员）+ Vue 3 SPA 完整 admin dashboard（agent manager）  [2026-05-19, REVISED via Q4=C + Q4-aux=Vue3+Vite]

**Context**：用户决策 Q4=C（完整 web admin），Q4-aux=Vue 3 + Vite。原 ADR-2 推荐的"砍掉 PR-5"已被否决。同时仍保留 `/plugin` 内置 TUI 作为团队成员侧首选接入（零学习成本）。

**Decision**：**双面板共存**。
- **团队成员**：通过 `/plugin marketplace add` + 内置 `/plugin` TUI 浏览安装（零依赖 web）。
- **Agent manager**：通过 `https://panel.uuhfn.cloud`（Vue 3 SPA，admin Bearer token）完成 browse / upload / approve / curate。
- bifrost-api 提供两组 endpoint：`/marketplace/{status,list,disk,logs}` 只读 + `/marketplace/admin/{upload,approve,curate,rerender}` 写入。
- 前端栈 = Vue 3 + Vite + Pinia + Vue Router，独立目录 `bifrost-api-web/`，build 产物 `dist/` 拷到 A 端 Caddy 静态服务。

**Consequences**：
- 团队成员 UX 不变（仍是 `/plugin`），零学习成本
- agent manager 拿到完整 web admin（含 upload / approve / curate / 审计日志查看）
- 引入 Node 20 LTS + npm/pnpm + Vite + Vitest 到项目，CI 矩阵复杂度+1（独立 `panel-build` job，不阻塞 Python CI）
- 新增 1 个公开子域 `panel.uuhfn.cloud`（**不**新增公网端口，复用 443）
- PR-5 单独 PR，含 SPA + admin SSH 通道 + JSON 写路由，~700~800 LOC（最接近 800 上限）
- 详细架构见 `spec.md §8`

### ADR-3 — 鉴权模型 = LAN-only 公开读 + `permissions.deny` 客户端兜底 + admin Bearer token 写入  [2026-05-19, LOCKED via Q5=A]

**Context**：现有 `npm.uuhfn.cloud` 是 LAN-only 公开读（依赖 nftables / wg 隔离做物理边界，无 htpasswd）。如果 marketplace 加 `htpasswd` 或 token 会带来：(1) 团队成员每个机器一个 token 的管理成本；(2) `/plugin marketplace add` 命令行带 token 的 UX 痛点；(3) 与现有 stack 不一致。

**Decision**：**marketplace.json + plugin tarball 走 LAN-only 公开读**（与 `npm.uuhfn.cloud` 完全一致的策略），**鉴权由网络边界（wg / nftables / `bind 10.8.0.2`）保证**。安全兜底放在客户端 `.claude/settings.json` 的 `permissions.deny`（hard-block 高危 hook）。bifrost-api `/marketplace/*` 仍走 admin Bearer token（与 `/mirrors/*` 一致）。

**Consequences**：
- 0 团队成员侧改动 → onboarding 体验最佳
- 与现有 stack 完全一致 → 维护负担最小
- 安全依赖网络层 → 一旦 wg / nftables 被 misconfig 风险变大（缓解：`tests/test-in-docker.sh` parity check + `docs/SECURITY.md` 鉴权矩阵）
- 客户端 hard-block 不可关 → agent manager 通过 git 控制 settings 模板，权限单点

### ADR-4 — Upstream LICENSE 合规 = DENY mirror anthropic/claude-code  [2026-05-19, LOCKED via WebFetch 实测]

**Context**：用户 Q3 答案 = "内部 + 官方"。实施 spec.md 阶段，按 team-lead 要求用 WebFetch 拉取 `https://github.com/anthropics/claude-code/blob/main/LICENSE.md`，实测结果：

> `© Anthropic PBC. All rights reserved. Use is subject to Anthropic's Commercial Terms of Service.`

进一步拉取 Commercial ToS（https://www.anthropic.com/legal/commercial-terms）：

> D.4：禁止"reverse engineer or duplicate the Services"；F：默认不授予任何 IP 权利。

**Decision**：**DENY mirror upstream**。降级 Q3 到 A（仅内部 plugin），不镜像 anthropic/claude-code 或任何 Anthropic proprietary 仓库。本任务范围内 marketplace 仅分发团队自研 plugin（license_id = "ALL-RIGHTS-RESERVED"，属本团队 IP）。

**Fallback path 保留**：
- `render-marketplace-json.sh` 保留 `metadata.upstream_url` 字段（设为 `null`）
- `scripts/check-upstream-schema.sh` 每日 cron 监控 Anthropic LICENSE 变更
- 一旦上游改 OSS license（MIT/Apache-2.0），启动 PR-1b（mirror upstream）

**Consequences**：
- PR-1b 标 **deferred / BLOCKED-on-LICENSE**，不进 MVP 交付
- `marketplace.json.metadata.upstream_url = null`、`license_id = "ALL-RIGHTS-RESERVED"`
- Agent manager UI 显示 "Internal-only marketplace" badge
- 法务零暴露：所有分发内容均为团队自有 IP
- 详细分析与 fallback 见 `spec.md §5`

---

## Related Tasks

| 任务 | 关系 | 备注 |
|---|---|---|
| `05-19-server-b-private-distribution`（已交付） | **依赖底座** | 本任务的 Caddy / fcgiwrap / systemd template / `/var/lib/dist/`、`/var/lib/git-mirrors/` 全部复用此任务交付物 |
| `05-19-0519-1-improvement`（in_progress） | **并行改进** | 如果其改进 touch 同一文件（如 `bifrost-readonly-router.sh`），需要 rebase 协调 |
| `05-19-server-a-hardening-v2` PR-3（in_progress） | **A 端反代** | 本任务 PR-3 (`Caddyfile-a.tpl` 改动) 需等其合入 main 后再启动 |
| `05-18-newapi-uuhfn-cloud-package`（in_progress） | **解耦** | 完全无关，平行存在 |

### 组合后的最终架构（合流后视图）

```
                                Internet
                                   │
                                   ▼
                ┌──────────────────────────────────────────┐
                │  Server A (uuhfn.cloud) — pure gateway   │
                │  • TLS terminate (Cloudflare Origin / LE)│
                │  • Caddy reverse_proxy → wg              │
                │  • bifrost-api FastAPI control plane     │
                │    /mirrors/*        (existing 0519-1)   │
                │    /marketplace/*    ◀── NEW (this task) │
                └────────────────┬─────────────────────────┘
                                 │ wg0 / 10.8.0.0/24
                                 ▼
        ┌────────────────────────────────────────────────────┐
        │  Server B (10.8.0.2) — stateful node               │
        │  • Verdaccio (npm)         :4873  (existing)       │
        │  • Caddy file_server       :8081  /var/lib/dist/   │
        │      └─ plugins/marketplace.json  ◀── NEW          │
        │      └─ plugins/<name>/releases/  ◀── NEW          │
        │      └─ releases/                 (existing)       │
        │  • Caddy git-http-backend  :8082  /git/*           │
        │      └─ claude-for-legal-zh.git   (existing)       │
        │      └─ bifrost-internal.git      ◀── NEW          │
        │  • NewAPI                  :3000  (existing)       │
        │  • systemd timers:                                 │
        │      git-mirror@claude-for-legal-zh.timer (existing)│
        │      git-mirror@bifrost-internal.timer    ◀── NEW  │
        │      restic-backup.timer  (existing)               │
        └────────────────────────────────────────────────────┘
```

---

## Definition of Done

- 上述所有 Acceptance Criteria 勾选
- 5~6 个 PR 全部合入 main（PR-5 视 Q4 决定）
- `tests/test-in-docker.sh` parity check 通过
- `docs/USAGE.md` + `docs/SECURITY.md` 新章节落地
- `gitnexus_impact` 在 implement 阶段每个 PR 至少跑一次（对齐 `CLAUDE.md` 约定）
- `gitnexus_detect_changes` 在 PR 合并前跑一次确认无溢出
- `prompts/0519-1/marketplace-bootstrap/` 含可独立 deploy 的 marketplace artifact
- 至少 1 名团队成员从干净笔记本走完 `/plugin marketplace add` → `/plugin install` 全流程，成功

---

## Technical Notes

### 影响文件预测

| 文件 | 改动量 | PR |
|---|---|---|
| `prompts/0519-1/marketplace-bootstrap/` | 新建（~300 行 yaml/md/sh） | PR-1 |
| `scripts/server-b.sh:2558+` (`enable_distribution`) | +60~100 行（新 step + helpers） | PR-2 |
| `configs/caddy/Caddyfile-b-distribution.tpl:10` | +10~20 行（path matcher） | PR-2 |
| `scripts/bifrost-readonly-router.sh` | +20 行（新 case arms） | PR-2 |
| `configs/caddy/Caddyfile-a.tpl:276-286` | +5~10 行（`@plugins` matcher） | PR-3 |
| `scripts/server-a.sh` | +20 行（inline Caddy parity） | PR-3 |
| `scripts/server-b.sh` (`_distribution_render_systemd_units`) | +15 行（新 timer instance） | PR-3 |
| `bifrost-api/app/routers/marketplace.py` | 新建 ~200 行 | PR-4 |
| `bifrost-api/app/main.py:128` | +1 行（include_router） | PR-4 |
| `tests/test_marketplace_router.py` | 新建 ~100~150 行 | PR-4 |
| `prompts/0519-1/team-config/` | 新建 ~50 行 templates | PR-6 |
| `docs/USAGE.md:589` | +60 行新章节 | PR-6 |
| `docs/SECURITY.md:97` | +40 行新章节 | PR-6 |
| `scripts/build-marketplace-seed.sh` | 新建 ~50 行 | PR-6 |

**总计**：~900~1100 行 production code/config + ~250 行 tests + ~150 行 docs。

### GitNexus 影响分析（implement 阶段必跑）

```bash
# Before PR-2: 改 enable_distribution
gitnexus_impact({target: "enable_distribution", direction: "upstream"})
gitnexus_context({name: "_distribution_render_caddy"})
gitnexus_context({name: "_distribution_mark_step_done"})

# Before PR-3: 改 Caddyfile-a 和 server-a.sh inline
gitnexus_impact({target: "setup_caddy_a", direction: "upstream"})
gitnexus_detect_changes({scope: "compare", base_ref: "main"})

# Before PR-4: 新 router 不会破坏现有，但仍跑
gitnexus_context({name: "require_admin"})
gitnexus_context({name: "_run_readonly_command"})

# Before each PR commit
gitnexus_detect_changes({scope: "staged"})
```

### Slot-in 点速查表

| 用途 | 文件 | 行号 | 改动方式 |
|---|---|---|---|
| 新增 deploy step | `scripts/server-b.sh` | 2558 | 在 `enable_distribution()` 内 step 06 后插入 step 07 |
| Caddy B 端 path matcher | `configs/caddy/Caddyfile-b-distribution.tpl` | 10 (`:8081` site) | 在 `root * /var/lib/dist` 块内加 `handle_path /plugins/*` |
| Caddy A 端 path matcher | `configs/caddy/Caddyfile-a.tpl` | 276~286 (`files.{{DOMAIN}}` 块) | 在 `@git` 块旁加 `@plugins` 块 |
| systemd timer instance | `scripts/server-b.sh` | 2640~2646 (`08_git_mirror` step) | 加 `systemctl enable --now git-mirror@bifrost-internal.timer` |
| bifrost-api router | `bifrost-api/app/main.py` | 128 | `app.include_router(marketplace_router.router)` |
| Settings 字段 | `bifrost-api/app/config.py` | 38~41 | **无需改动**（复用 `server_b_wg_ip` / `readonly_*`） |
| readonly SSH 白名单 | `scripts/bifrost-readonly-router.sh` | case arms | 加 `logs:git-mirror-bifrost-internal`、`marketplace:stat` |
| docs | `docs/USAGE.md` | 589（`## Server B 私有分发栈`） | 新增 `### 内部 Claude marketplace` 子章节 |
| security docs | `docs/SECURITY.md` | 97（`### Server B 私有分发栈安全边界`） | 新增 `### 内部 Claude marketplace 安全边界` 子章节 |

---

## Research References

- **Anthropic "Claude Code at Scale" 文章**（research arm A 调研产出）：plugin = 分发单元 / managed marketplace / agent manager 角色 / CLAUDE.md 层级
- **Claude Code 原生 `/plugin marketplace` 协议**（research arm B 关键发现）：`/plugin marketplace add` CLI、git/url/npm/path source types、`~/.claude/plugins/cache/` 落盘、`extraKnownMarketplaces` + `enabledPlugins` 集中下发、reserved names、`CLAUDE_CODE_PLUGIN_SEED_DIR` 离线 bootstrap
- **现有 Server B distribution 栈**（research arm C / 0519-1 已交付）：Caddy `:8081/:8082`、Verdaccio、git-mirror systemd template、`/var/lib/dist`、`/var/lib/git-mirrors`、`bifrost-readonly-router.sh`、bifrost-api `/mirrors/*`

---

> **下一步**：用户回答 ★ 标记的 Q1 / Q2 / Q4 后，本 PRD 进入 spec.md 阶段（与 `prompts/0519-1/spec.md` 同等深度的设计冻结），随后 PR-1 启动。
