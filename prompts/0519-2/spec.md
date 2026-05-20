# SPEC v2 — Server B 内部 Claude artifacts marketplace + visual panel

> **Bound PRD**: `prd.md` (Q1-Q7 + Q4-aux + ADR-1..ADR-4 全锁) ｜ **Bound Review**: `spec-review.md` (31 findings: 6C / 19M / 6N) ｜ **Composes**: `prompts/0519-1/spec.md` (distribution 栈底座 design-frozen v2)
> **Status**: design-frozen v2 | **Updated**: 2026-05-19
> **Authoring rule**: 所有 file:line 锚点基于本地仓库 HEAD（main 分支）实测过；所有协议字段基于 `https://code.claude.com/docs/en/plugin-marketplaces.md`（WebFetch 实拉）

> v2 变更概览：闭合 6C+19M+6N（详见 `spec-review.md`）。最关键修复：(a) marketplace.json 落地在 git tree `.claude-plugin/` 而不是 dist 旁路；(b) protocol 字段 `owner` = object、`source` 鉴别字段名 = `source` 而非 `type`；(c) `/plugin marketplace add` URL 不带 `git+` 前缀；(d) auth header 从 `Authorization: Bearer` 改回 `X-Admin-Key`（与 `bifrost-api/app/dependencies.py:40` 实际实现一致）；(e) `panel.uuhfn.cloud` 强制 `@panel_private remote_ip {{ADMIN_ALLOWED_RANGES}}` vpn-first allowlist（M3 升 MVP blocker）；(f) PR-5 拆 5a/5b；(g) marketplace-render 走 git worktree → commit → push 回 bare；(h) `bifrost-internal-plugins` 不进 git-mirror-sync 矩阵（C6 自指死锁）。

---

## 0. 总览

### 0.1 顶层拓扑

```
                            INTERNET
                                |
                                v
                ┌──────────────────────────────────┐
                │  Cloudflare DNS (灰云)            │
                │  *.uuhfn.cloud → A 公网 IP        │
                └─────────────────┬─────────────────┘
                                  v
  ┌──────────────────── SERVER A (10.8.0.1, 国内) ───────────────────────┐
  │  公网入站：80/443/tcp(Caddy) + 22/tcp + 51820/udp(WG)                 │
  │  Caddy (TLS 终止)                                                      │
  │    ├─ api.uuhfn.cloud         → 10.8.0.2:3000 (NewAPI)                │
  │    ├─ npm.uuhfn.cloud         → 10.8.0.2:4873 (Verdaccio)             │
  │    ├─ files.uuhfn.cloud                                                │
  │    │    ├─ /git/*             → 10.8.0.2:8082 (git smart-HTTP RO)     │
  │    │    │    └─ bifrost-internal-plugins.git ◀── NEW                  │
  │    │    └─ (default)          → 10.8.0.2:8081 (files browse)          │
  │    └─ panel.uuhfn.cloud ◀── NEW                                        │
  │         • @panel_private { remote_ip {{ADMIN_ALLOWED_RANGES}} } 必须强制│
  │         • SPA static + /api/* + /marketplace/* → 127.0.0.1:8000        │
  │  bifrost-api (127.0.0.1:8000)                                          │
  │    ├─ /mirrors/* (existing)                                            │
  │    ├─ /marketplace/* ◀── NEW (admin-gated, X-Admin-Key 头)             │
  │    └─ /marketplace/admin/* ◀── NEW (写入路由，admin-gated)             │
  └────────────────────────────────────┬──────────────────────────────────┘
                                       │ wg0 / 10.8.0.0/24
                                       v
  ┌──────────────── SERVER B (10.8.0.2, 海外，vpn-first) ────────────────┐
  │  公网入站：22/tcp + 51820/udp，其它 DROP（无新增端口）                │
  │                                                                       │
  │  Caddy on wg0:8081  /var/lib/dist/   (file_server browse, existing)   │
  │      └─ 本任务不在此路径下放 marketplace.json sidecar (C1 撤销)        │
  │                                                                       │
  │  Caddy on wg0:8082  /var/lib/git-mirrors/  (git smart-HTTP RO)        │
  │    ├─ claude-for-legal-zh.git           (existing)                    │
  │    └─ bifrost-internal-plugins.git ◀── NEW (bare, 唯一权威源)         │
  │       └─ .claude-plugin/marketplace.json (in tree, push 后存在)       │
  │                                                                       │
  │  systemd units:                                                        │
  │    git-mirror@claude-for-legal-zh.timer    (existing, daily 02:00)    │
  │    marketplace-render.path             ◀── NEW (watch packed-refs)    │
  │    marketplace-render.service          ◀── NEW (oneshot worktree→push)│
  │    upstream-schema-check.timer         ◀── NEW (daily LICENSE 监控)   │
  │  注：bifrost-internal-plugins 不进 git-mirror-sync 矩阵（C6 修复）    │
  └───────────────────────────────────────────────────────────────────────┘

  Team laptop
  ───────────
  /plugin marketplace add https://files.uuhfn.cloud/git/bifrost-internal-plugins.git
                          ▲ 无 git+ 前缀；client 实际执行 git clone 拉到本地
  /plugin install hello-world-skill@bifrost-internal
                          ▲ client 读取 clone 副本下 .claude-plugin/marketplace.json
                          ▲ 解析 plugins[].source = "./plugins/hello-world-skill"（相对路径）
                          ▲ 从同一 clone 副本拷贝该子目录到 ~/.claude/plugins/cache/

  Agent manager (admin)
  ─────────────────────
  https://panel.uuhfn.cloud/  (Vue SPA, X-Admin-Key header; page routes: /plugins, /status, /upload, /curate)
    ├─ Browse   (/plugins → GET /marketplace/list)
    ├─ Status   (/status → GET /marketplace/status)
    ├─ Upload   (/upload → POST /marketplace/admin/upload, multipart)
    └─ Curate   (/curate → POST /marketplace/admin/curate / approve)
  必须先通过 @panel_private remote_ip 网络层验证（vpn-first），再过 X-Admin-Key 应用层验证。
```

### 0.2 数据流（marketplace render 修订版，C1+M18 闭合）

```
  agent manager 通过 panel POST /marketplace/admin/upload
    │
    │ multipart: tarball=hello-world-skill-v0.2.0.tar.gz + manifest=manifest.yaml
    │
    v
  bifrost-api /marketplace/admin/upload (require_admin X-Admin-Key)
    │ 1. 解压 tarball 到临时目录，校验 manifest.yaml schema
    │ 2. SSH 到 B：bifrost-admin-router.sh upload <plugin-name> <version>
    │
    v
  Server B bifrost-admin-router.sh (forced-command SSH)
    │ 1. git clone /var/lib/git-mirrors/bifrost-internal-plugins.git /tmp/marketplace-work-<uuid>
    │ 2. cp -r plugin-extracted/* /tmp/marketplace-work/plugins/<name>/
    │ 3. cd worktree && git add . && git commit -m "Upload <name> v<X.Y.Z>"
    │ 4. git tag -a plugins/<name>/v<X.Y.Z> -m "Release"
    │ 5. git push origin main --tags
    │ 6. rm -rf /tmp/marketplace-work-<uuid>
    │
    v
  bare /var/lib/git-mirrors/bifrost-internal-plugins.git/packed-refs CHANGE
    │
    v
  systemd path unit: marketplace-render.path (PathModified=packed-refs + refs/tags)
    │ Requires=marketplace-render.service exists
    │ After=network-online.target (本仓库不进 git-mirror，所以仅 After=network)
    │
    v
  systemd service: marketplace-render.service (oneshot)
    │ User=git-mirror, /usr/local/bin/render-marketplace-json.sh
    │ 1. git clone bare to /tmp/render-work-<uuid>
    │ 2. 扫描 refs/tags/plugins/<name>/v<semver>
    │ 3. 校验每个 plugin/<name>/.claude-plugin/plugin.json 与 manifest.yaml
    │ 4. 渲染 .claude-plugin/marketplace.json（schema 见 §4.1）
    │ 5. 写 LICENSE / NOTICE 到 worktree 根（§5.3）
    │ 6. git add .claude-plugin/marketplace.json LICENSE NOTICE
    │ 7. git -c user.name=marketplace-render -c user.email=render@uuhfn.cloud commit -m "render @ <iso8601>"
    │ 8. git push origin main
    │ 9. 写 /var/lib/dist/plugins/state.json (含 last_render_ts / upstream_alert) 供 status 路由读取
    │ 10. rm -rf /tmp/render-work-<uuid>
    │
    v
  Caddy :8082 (read-only smart-HTTP) 立即可见
    │
    v
  Client: /plugin marketplace update bifrost-internal
    │ → git pull → 看到新版 .claude-plugin/marketplace.json + plugins/<name>/ 新代码
    │ → /plugin install <name>@<ver>
```

**关键修复**（spec-review C1+M18）：marketplace.json 是 git tree 内的文件，不是 dist 旁路。客户端永远只看 git clone 的副本。`/var/lib/dist/plugins/` 不再用于存放 marketplace.json，只用于存放 `state.json`（render 状态）和 `LICENSE.md`/`NOTICE.md` 应急只读副本（虽然 git tree 内也有同名文件，但通过 dist 提供一个 status endpoint 友好的 URL）。

---

## 1. IP / 端口 / 服务清册

### 1.1 marketplace 相关服务清单（Server B 增量）

> 与 `prompts/0519-1/spec.md §1.1` 合并。下表仅列**本任务新增 / 改动**条目。**无新增端口**。

| 服务 | 接口 | 端口 | 进程 | 持久化 |
|---|---|---|---|---|
| Git bare: bifrost-internal-plugins | wg0 | 8082（复用，via fcgiwrap） | `git-http-backend` | `/var/lib/git-mirrors/bifrost-internal-plugins.git` |
| marketplace-render | (path unit) | — | `marketplace-render.service` (User=git-mirror) | `/tmp/render-work-<uuid>` (临时) + commits → bare |
| upstream-schema-check | (timer, daily) | — | `upstream-schema-check.service` | `/var/log/marketplace/schema-check.log` |
| state.json (render 状态) | wg0 | 8081（复用 `/var/lib/dist/`） | caddy file_server | `/var/lib/dist/plugins/state.json` |
| (Server A) bifrost-api `/marketplace/*` | lo | 8000（复用） | bifrost-api.service | none (read-thru) |
| (Server A) panel.uuhfn.cloud | 443/tcp | 443（复用） | caddy（SPA static + /api+/marketplace 反代 8000） | `/var/www/bifrost-api-web/dist/` |

> **注 N2**：panel.uuhfn.cloud 进程行简化 — Caddy 反代 `/api` + `/marketplace` 到 bifrost-api，其余路径服务 SPA 静态资源。

### 1.2 端口 baseline 对比

```
Before (0519-1 baseline)                After (本任务交付完成)
  A pub: 22/tcp 80/tcp 443/tcp 51820/udp  A pub: 22/tcp 80/tcp 443/tcp 51820/udp  ← 不变
  B pub: 22/tcp 51820/udp                 B pub: 22/tcp 51820/udp                 ← 不变
```

**关键不变量**：`nmap -p- <SERVER_B_PUBLIC_IP>` 输出必须与 0519-1 完全一致。AC-1 验证。

### 1.3 域名 / 鉴权矩阵

| 域名 | 用途 | 网络层 | 应用层 |
|---|---|---|---|
| `files.uuhfn.cloud/git/bifrost-internal-plugins.git` | git clone source | A 端 Caddy 终止 TLS，无 remote_ip 限制（LAN-only-by-design） | 无（push 已被 fcgiwrap 配置 403） |
| `panel.uuhfn.cloud/*` | Vue admin SPA + API JSON | **强制 `@panel_private remote_ip {{ADMIN_ALLOWED_RANGES}}`（M3）** | `X-Admin-Key` header（require_admin） |

> **N5+M3 解决**：admin 写路由不能仅靠 token 应用层防护，必须叠加网络层 vpn-first allowlist；leaked token 不会演变成生产 breach。`{{ADMIN_ALLOWED_RANGES}}` 默认 `10.8.0.0/24 127.0.0.1/32`，与 hardening-v2 PR-3 完全一致。

> **DNS 要求**：需在 Cloudflare 加 `panel.uuhfn.cloud` A 记录 → A 公网 IP（灰云）。AC-13 验证。

---

## 2. nftables 增量

**预期 = 0 行规则变更**。

- B 端：marketplace 流量复用 `iifname "wg0" accept`，无新端口。
- A 端：`panel.uuhfn.cloud` 走 443，复用 `accept tcp dport {80,443}`，**网络层 allowlist 在 Caddy `@panel_private remote_ip` 处实现**（而非 nftables），与现有 `api.uuhfn.cloud/manage/*` 同款。

---

## 3. Caddy 配置规范

### 3.1 Server A 改动（`configs/caddy/Caddyfile-a.tpl:276-286` `files.{{DOMAIN}}` 块）

**关键修复（C1）**：撤销之前在 spec v1 §3.1 提出的 `@plugins path /plugins/*` matcher — client 不消费 dist 旁路 marketplace.json，所以 `files.uuhfn.cloud/plugins/*` 不再是 client 接入点。但保留 `/plugins/state.json` 作为 bifrost-api 探活辅助路径（读 render 状态）。**因此 `files.{{DOMAIN}}` 块改动极小**：

```caddy
files.{{DOMAIN}} {
    tls {{TLS_CERT_FILE}} {{TLS_KEY_FILE}}
    encode gzip

    @git path /git/*
    handle @git {
        import server_b_proxy http://10.8.0.2:8082
    }
    handle {
        # 默认 file_server，包含 state.json / LICENSE.md / NOTICE.md 应急读取
        import server_b_proxy http://10.8.0.2:8081
    }
}
```

> **结论**：files.{{DOMAIN}} 块**无新增 path matcher**（与 spec v1 不同），仅 PR-3 文档级补充。

### 3.2 Server A `panel.uuhfn.cloud`（新增站点，必须 vpn-first）

追加在 `files.{{DOMAIN}}` 块之后：

```caddy
panel.{{DOMAIN}} {
    tls {{TLS_CERT_FILE}} {{TLS_KEY_FILE}}
    encode gzip

    # M3: 必须强制 vpn-first，与 api.uuhfn.cloud 的 @newapi_private 同款
    @panel_private {
        remote_ip {{ADMIN_ALLOWED_RANGES}}
    }
    @panel_public {
        not remote_ip {{ADMIN_ALLOWED_RANGES}}
    }

    # 拒绝非 allowlist 来源（防止公网爆破 admin token）
    handle @panel_public {
        respond "Bifrost marketplace panel requires VPN/private access in vpn-first profile" 403
    }

    handle @panel_private {
        # M2: API 反代必须传 header_up（与 server_b_proxy snippet 同款）
        @api_or_marketplace path /api/* /marketplace/* /marketplace
        handle @api_or_marketplace {
            reverse_proxy 127.0.0.1:8000 {
                header_up X-Real-IP {remote_host}
                header_up X-Forwarded-For {remote_host}
                header_up X-Forwarded-Proto {scheme}
                header_up Host {host}
                transport http {
                    dial_timeout 5s
                    response_header_timeout 30s
                }
            }
        }

        # SPA 静态资源 + vue-router history fallback
        handle {
            root * /var/www/bifrost-api-web/dist
            try_files {path} /index.html
            file_server
            # 资产长缓存
            @assets path /assets/*
            header @assets Cache-Control "public, max-age=31536000, immutable"
        }
    }
}
```

> **N5 解决**：site 块顶层 matcher 拒绝非 allowlist 客户端，整个 SPA 仅在 VPN/管理网段可见。
> **M2 解决**：API 反代显式 `header_up`，bifrost-api 看到正确 Host = `panel.uuhfn.cloud`。
> **M4 解决**：API 反代 + SPA 静态都加 `dial_timeout 5s` / `transport http`，防止后端 stall 引起前端长卡。

### 3.3 Server B 改动（`configs/caddy/Caddyfile-b-distribution.tpl:9-19` `:8081` site）

**关键修复（C1）**：marketplace.json 不再写到 `/var/lib/dist/plugins/`。Caddy B 端 `:8081` 块**几乎不需要改动**，只在 `state.json` / `LICENSE.md` / `NOTICE.md` 应急只读副本目录下加 ETag 友好的 header：

```caddy
{{SERVER_B_WG_IP}}:8081 {
    # 唯一改动：为 /plugins/state.json 等小型 status 资源加 cache 友好 header
    @plugins_status path /plugins/state.json /plugins/LICENSE.md /plugins/NOTICE.md
    handle @plugins_status {
        root * /var/lib/dist
        file_server
        header Cache-Control "no-cache, must-revalidate"
        header ETag "{file.modtime_unix}-{file.size}"
    }

    # 现有默认 browse（不变）
    root * /var/lib/dist
    file_server browse
    encode gzip
    log {
        output file /var/log/caddy/files.log {
            roll_size 50mb
            roll_keep 7
        }
    }
}
```

`:8082` git smart-HTTP 块**完全不动**（push 已 403）。

---

## 4. marketplace.json 协议规范（基于 docs.claude.com 实拉）

### 4.1 schema 1:1 对齐官方协议（C1+C2+C3 闭合）

**所有字段名 / 类型 / 嵌套结构与 `https://code.claude.com/docs/en/plugin-marketplaces.md` 完全一致**。

**文件路径**：`<repo>/.claude-plugin/marketplace.json`（**git tree 内**，不在 dist sidecar）。

**Top-level required**：`name` (string)、`owner` (**object** with required `name`, optional `email`)、`plugins` (array)。

**Plugin entry required**：`name` (string)、`source` (**string OR object**)。

**Plugin source 鉴别字段名是 `source`，不是 `type`**（C2 修复）。每个 source 变体：

| source 形态 | 字段 | 用法 |
|---|---|---|
| string starting `./` | （无嵌套字段） | Relative path within marketplace repo（**本任务采用，因为是 monorepo**） |
| `{source: "github", repo, ref?, sha?}` | `repo` (owner/repo) | GitHub 仓库 |
| `{source: "url", url, ref?, sha?}` | full git URL | 任意 git 主机 |
| `{source: "git-subdir", url, path, ref?, sha?}` | url + path | 单独 git 仓库 monorepo 子目录 |
| `{source: "npm", package, version?, registry?}` | npm package | npm 包 |

> **本任务的 plugin source 全部用 relative path string**（如 `"./plugins/hello-world-skill"`）。理由：marketplace 本身是 monorepo，所有 plugin 都在同一 git tree 内，client `git clone` 之后直接读子目录，**无须** `git-subdir` 的 sparse-clone 复杂度，也不需要外部 GitHub。

**完整 marketplace.json**（PR-1 sample，PR-1 中即可 commit 到 git seed）：

```json
{
  "name": "bifrost-internal",
  "owner": {
    "name": "Bifrost Team",
    "email": "bifrost-admin@uuhfn.cloud"
  },
  "description": "Bifrost 团队内部 Claude Code plugin marketplace（仅团队内分发，不镜像上游）",
  "version": "1.0.0",
  "metadata": {
    "pluginRoot": "./plugins",
    "license_id": "ALL-RIGHTS-RESERVED",
    "upstream_url": null,
    "rendered_at": "2026-05-19T11:30:00Z",
    "render_script_version": "v1.0.0",
    "git_head_sha": "abc1234567890def..."
  },
  "plugins": [
    {
      "name": "hello-world-skill",
      "source": "./plugins/hello-world-skill",
      "description": "Sample skill demonstrating marketplace plumbing",
      "version": "0.1.0",
      "author": {
        "name": "Bifrost Team",
        "email": "bifrost-admin@uuhfn.cloud"
      },
      "license": "ALL-RIGHTS-RESERVED",
      "keywords": ["sample", "internal"],
      "category": "demo",
      "strict": true
    }
  ]
}
```

> 关键点：
> - **`owner` 是 object**，spec v1 写 string 的错误已纠正。
> - **`source: "./plugins/hello-world-skill"` 是 string**，client 在 clone 后读相对路径。
> - **没有** `tarball_url` / `tarball_sha256` 字段（C2 N4）— 协议不消费 tarball。
> - **没有** `type` 字段（C2）— 鉴别字段是 `source`，但本任务用相对路径不嵌套对象，所以根本没有该字段。
> - `metadata.pluginRoot = "./plugins"` 允许后续新增 plugin 时 `source` 写 `"hello-world-skill"` 而不是 `"./plugins/hello-world-skill"`（docs §Optional fields）。

### 4.2 render-marketplace-json.sh 接口规范（M18 闭合）

**位置**：`scripts/render-marketplace-json.sh`（PR-1 产出，安装到 `/usr/local/bin/render-marketplace-json.sh` by PR-2）

**入参**：

```bash
render-marketplace-json.sh <repo-slug> <bare-path>
# 例：
#   render-marketplace-json.sh bifrost-internal-plugins \
#       /var/lib/git-mirrors/bifrost-internal-plugins.git
```

**行为契约**：

1. 创建临时 worktree：`work=$(mktemp -d /tmp/render-work.XXXXXX); git clone "$bare" "$work"`
2. `cd $work && git for-each-ref refs/tags/plugins/*/v*` 列所有 plugin tag
3. 对每个 tag 解析 `plugins/<name>/v<X.Y.Z>` 形式：
   - 校验 `plugins/<name>/.claude-plugin/plugin.json` 的 `version` 与 tag 一致（不一致 exit 3）
   - 校验 `plugins/<name>/manifest.yaml`（本仓库附加字段，§6.4）
4. 渲染 `.claude-plugin/marketplace.json`（§4.1 schema）写入 worktree（**不是** dist sidecar）
5. 写 `LICENSE` / `NOTICE` 到 worktree 根（§5.3 内容）
6. `git add . && git -c user.name=marketplace-render -c user.email=render@uuhfn.cloud commit -m "render @ $(date -Iseconds)"`（若 diff 为空则 exit 0 跳过 commit）
7. `git push origin main`
8. 写 `/var/lib/dist/plugins/state.json` 给 bifrost-api 探活用：
   ```json
   {
     "last_render_ts": "2026-05-19T11:30:00Z",
     "latest_git_head": "abc123...",
     "plugin_count": 1,
     "upstream_alert": false,
     "render_script_version": "v1.0.0"
   }
   ```
9. 应急副本：`cp $work/LICENSE /var/lib/dist/plugins/LICENSE.md`、`cp $work/NOTICE /var/lib/dist/plugins/NOTICE.md`
10. `rm -rf $work`

**退出码**：0 = 成功（含 no-op），2 = usage 错误，3 = schema/版本不匹配，4 = git 操作失败，5 = manifest 校验失败。

**幂等保证**：相同 git_head_sha 下重复执行不产生新 commit（步骤 6 检查 `git diff --quiet`）。

### 4.3 触发机制（M5+M7+M19 闭合）

```ini
# /etc/systemd/system/marketplace-render.path
[Unit]
Description=Watch bifrost-internal-plugins refs for changes
# M19: bare 不一定存在到 path unit 加载时，但本任务 step 07 显式预创建
# 不需 Requires=git-mirror@...service（C6: bifrost-internal-plugins 不进 git-mirror 矩阵）

[Path]
# M5: PathModified 监 modify 事件（PathChanged 仅 create/delete）
PathModified=/var/lib/git-mirrors/bifrost-internal-plugins.git/packed-refs
PathModified=/var/lib/git-mirrors/bifrost-internal-plugins.git/refs
MakeDirectory=true
Unit=marketplace-render.service

[Install]
WantedBy=multi-user.target
```

```ini
# /etc/systemd/system/marketplace-render.service
[Unit]
Description=Render bifrost-internal marketplace.json into git tree
# M7: 等待网络（git push 走 file://，但 future 远端化保险）
Requires=network-online.target
After=network-online.target
ConditionPathExists=/var/lib/git-mirrors/bifrost-internal-plugins.git/HEAD

[Service]
Type=oneshot
User=git-mirror
Group=git-mirror
ExecStart=/usr/local/bin/render-marketplace-json.sh bifrost-internal-plugins /var/lib/git-mirrors/bifrost-internal-plugins.git
StandardOutput=append:/var/log/marketplace/render.log
StandardError=append:/var/log/marketplace/render.log
TimeoutStartSec=120
```

```ini
# /etc/systemd/system/upstream-schema-check.timer
[Unit]
Description=Daily check for Anthropic LICENSE / marketplace protocol changes

[Timer]
OnCalendar=daily
RandomizedDelaySec=30m
Persistent=true

[Install]
WantedBy=timers.target
```

```ini
# /etc/systemd/system/upstream-schema-check.service
[Unit]
Description=Check upstream Anthropic LICENSE for changes
# M7
Requires=network-online.target
After=network-online.target

[Service]
Type=oneshot
User=git-mirror
ExecStart=/usr/local/bin/check-upstream-schema.sh
StandardOutput=append:/var/log/marketplace/schema-check.log
StandardError=append:/var/log/marketplace/schema-check.log
TimeoutStartSec=60
```

> **M19**：在 `enable_distribution()` step 07 末尾**显式 enable**：
> ```bash
> systemctl enable --now marketplace-render.path
> systemctl enable --now upstream-schema-check.timer
> ```

---

## 5. LICENSE-Compliance（含 ADR-4 锁定）

### 5.1 Analysis（基于 WebFetch 实测 — 已二次校验）

**Source 1 — claude-code LICENSE** (https://github.com/anthropics/claude-code/blob/main/LICENSE.md, raw URL 返回 404 但 HTML UI 返回正文)：

```
© Anthropic PBC. All rights reserved.
Use is subject to Anthropic's Commercial Terms of Service.
```

**Source 2 — Anthropic Commercial Terms of Service** (https://www.anthropic.com/legal/commercial-terms)：

> D.4: "Customer may not and must not attempt to ... (b) reverse engineer or duplicate the Services"
> F: "Except as expressly stated in these Terms, these Terms do not grant either party any rights to the other's content or intellectual property, by implication or otherwise."

**分类结果**：

| 维度 | 判定 |
|---|---|
| License identifier | **PROPRIETARY**（"All Rights Reserved"，非任何 OSI license） |
| 版权人 | Anthropic PBC |
| Redistribution 显式授予 | **NO** |
| Mirror 显式许可 | **NO** |
| 合规决策矩阵触发 | **DENY** |

### 5.2 ADR-4 — DENY mirror anthropic/claude-code  [2026-05-19, LOCKED via WebFetch 实测]

**Decision**：**DENY**。Q3 自动降级到"A 仅内部"。PR-1b（mirror upstream）标 `BLOCKED-on-LICENSE / deferred`。

**Fallback path**（启动 PR-1b 的触发条件）：
- `scripts/check-upstream-schema.sh` 每日 cron 监控 Anthropic LICENSE
- 一旦检测到 LICENSE 变为 OSS license（如 MIT/Apache-2.0），自动写 alert 到日志 + state.json
- agent manager 评估后启动 PR-1b

**Consequences**：
- PR-1b 不计入 MVP
- `marketplace.json.metadata.upstream_url = null` / `license_id = "ALL-RIGHTS-RESERVED"`
- Vue admin panel 显示 "Internal-only marketplace" badge
- 法务零暴露

### 5.3 强制 LICENSE / NOTICE 输出（render 必产物）

**LICENSE**（写入 worktree 根，commit 到 bare）：
```
# bifrost-internal Plugin Marketplace
# Copyright (c) 2026 Bifrost Team. All rights reserved.
#
# Each plugin under `plugins/<name>/` may carry its own LICENSE file.
# Default policy: ALL-RIGHTS-RESERVED unless otherwise stated.
# Distribution restricted to authenticated Bifrost team members.
```

**NOTICE**（同上）：
```
This marketplace is an internal distribution channel for Bifrost team.
It does NOT mirror anthropic/claude-code or any other proprietary upstream.
Plugin submissions are subject to admin review via panel.uuhfn.cloud
(see docs/SECURITY.md §marketplace).
```

### 5.4 `scripts/check-upstream-schema.sh`（PR-7 产出，~80 行 bash）

**核心输出格式**（C5 闭合）— 必须打印明确状态码：

```bash
#!/usr/bin/env bash
set -euo pipefail

UPSTREAM_LICENSE_URL="https://github.com/anthropics/claude-code/raw/main/LICENSE.md"
BASELINE_SHA256_FILE="/etc/bifrost-api/marketplace/upstream-license-baseline.sha256"
STATE_FILE="/var/lib/dist/plugins/state.json"

current_sha256=$(curl -fsSL "$UPSTREAM_LICENSE_URL" | sha256sum | awk '{print $1}')
baseline_sha256=$(cat "$BASELINE_SHA256_FILE" 2>/dev/null || echo "")

ts=$(date -Iseconds)
if [[ -z "$baseline_sha256" ]]; then
    echo "$current_sha256" > "$BASELINE_SHA256_FILE"
    echo "LICENSE-BASELINE-INIT $current_sha256 $ts"
    upstream_alert=false
elif [[ "$current_sha256" == "$baseline_sha256" ]]; then
    echo "LICENSE-OK $current_sha256 $ts"
    upstream_alert=false
else
    echo "UPSTREAM-CHANGED $baseline_sha256 -> $current_sha256 $ts"
    upstream_alert=true
fi

# 更新 state.json 的 upstream_alert 字段（保留其他字段）
tmp=$(mktemp); jq --argjson a "$upstream_alert" '.upstream_alert = $a | .upstream_last_check_ts = "'"$ts"'"' "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
```

输出第一行 grep 正则：`^(LICENSE-OK|LICENSE-BASELINE-INIT|UPSTREAM-CHANGED) [0-9a-f]{64}`，AC-12 直接断言。

---

## 6. plugin git tag 工作流

### 6.1 仓库结构（monorepo + relative-path source）

> **N4+C1 闭合**：`.claude-plugin/marketplace.json` 必须在 git tree 根（不在 dist sidecar）。

```
bifrost-internal-plugins.git (bare on B:/var/lib/git-mirrors/)
└── refs/heads/main
    .claude-plugin/
      marketplace.json       ◀── 协议文件，render 输出
    plugins/
      hello-world-skill/
        .claude-plugin/
          plugin.json        ◀── Claude Code 原生 plugin manifest (协议字段)
        manifest.yaml        ◀── 本仓库附加字段（version / license_id / requires）
        skills/
          hello/SKILL.md
        LICENSE
        README.md
    LICENSE                  ◀── render 产出
    NOTICE                   ◀── render 产出
    README.md
└── refs/tags/
      plugins/hello-world-skill/v0.1.0   (annotated)
      plugins/hello-world-skill/v0.2.0
```

### 6.2 版本约定

- **tag 格式**：`plugins/<name>/v<X.Y.Z>` annotated tag
- **`.claude-plugin/plugin.json` `version`** 必须 = tag 的 semver（render exit 3 if mismatch）
- **`.claude-plugin/marketplace.json` `plugins[].version`** 不强制（协议允许 omit，commit SHA 自动作 version），但 render 脚本写入便于探活
- **禁止 floating main**：客户端 `/plugin install <name>@<ver>` 时通过 `ref` 拉对应 tag

### 6.3 上传 / 审批流程（M17 闭合 — 明确 PR review 入口）

**唯一合法上传通道**：通过 `panel.uuhfn.cloud` → bifrost-api admin endpoint → SSH 到 B 上 bifrost-admin-router.sh：

```
开发者 (本地)：
  1. 本地 git clone https://files.uuhfn.cloud/git/bifrost-internal-plugins.git
     （此 clone 是 read-only：fcgiwrap 已配置 push 403）
  2. 本地写 plugins/<name>/ + 测试
  3. 构建 tarball：tar czf hello-v0.2.0.tar.gz -C plugins/hello-world-skill .
  4. 准备 manifest.yaml
  5. 通过浏览器（在 VPN/管理网段内）访问 https://panel.uuhfn.cloud/upload
  6. Vue SPA 表单上传 tarball + manifest（X-Admin-Key header by login session）
  7. Bifrost-api 接收 → SSH 到 B → admin-router 拉 tag + push 回 bare
  8. marketplace-render.path 触发 → render → marketplace.json 自动更新
  9. 团队成员 /plugin marketplace update bifrost-internal 即可看到新版本

Agent manager 审批 (Curate)：
  /marketplace/admin/curate { plugin, action: "feature" | "deprecate" | "remove" }
  → 在 marketplace.json metadata 标注 featured/deprecated 字段（不影响协议主体）

注：dev 不直接 push 到 bare，因为：
  - fcgiwrap 已 403 receive-pack（Caddyfile-b-distribution.tpl:22-28 hardcoded）
  - PR review = panel.uuhfn.cloud admin 用 /admin/approve 决定接收/拒绝上传
  - 所有动作记入 /var/log/marketplace/admin-audit.log
```

### 6.4 manifest.yaml schema（本仓库附加）

```yaml
# plugins/<name>/manifest.yaml
version: "0.1.0"                       # 必须与 tag semver 一致（render exit 3 if mismatch）
description: "What this plugin does"   # 必填
license_id: "ALL-RIGHTS-RESERVED"      # 必填
maintainers:
  - name: "Alice"
    email: "alice@uuhfn.cloud"
requires:
  claude_code_min_version: "2.1.0"
  os: ["linux", "darwin", "windows"]
permissions:
  declared_hooks: []
  declared_mcp_servers: []
  declared_skills: ["hello"]
```

render-marketplace-json.sh 将这些字段 merge 进 `.claude-plugin/marketplace.json.plugins[]`，但不破坏官方协议字段（额外字段挂在 `plugins[].metadata.*` 命名空间下，与协议规定 optional 字段并存）。

---

## 7. bifrost-api `/marketplace/*` 路由契约（auth 统一 — C4+M8 闭合）

### 7.1 模式

完全克隆 `bifrost-api/app/routers/mirrors.py:1-225` 的写法，并 **复用 `app.dependencies.require_admin`**（实测于 `bifrost-api/app/dependencies.py:40-54`，**严格要求 `X-Admin-Key` header**）：

```python
from ..dependencies import require_admin

router = APIRouter(
    prefix="/marketplace",
    tags=["内部 Marketplace"],
    dependencies=[Depends(require_admin)],
)
```

> **C4 修复**：spec v1 错误指定 `Authorization: Bearer`，与 production `require_admin` (`x_admin_key: str | None = Header(None, alias="X-Admin-Key")`) 直接冲突。**统一改回 `X-Admin-Key`**。

> **M8 修复**：**删除** spec v1 §8.6 提议的 `POST /api/auth/verify` endpoint —— bifrost-api 无此路由（grep 确认）。Vue SPA 改用"首次受保护请求 200/401 决定"模式（详见 §8.6）。

### 7.2 OpenAPI-like 契约

| Method | Path | Auth | Body | 200 Response |
|---|---|---|---|---|
| `GET` | `/marketplace/status` | X-Admin-Key | — | `{up, last_render_ts, latest_git_head, plugin_count, disk_used_mb, upstream_alert, upstream_last_check_ts}` |
| `GET` | `/marketplace/list` | X-Admin-Key | — | `{plugins: [<plugin entries from .claude-plugin/marketplace.json>]}` |
| `GET` | `/marketplace/disk` | X-Admin-Key | — | `{var_lib_git_mirrors_bifrost_internal_plugins_mb, var_lib_dist_plugins_mb}` |
| `GET` | `/marketplace/logs?service={render\|schema-check\|admin-audit}` | X-Admin-Key | — | `text/plain` 200 行 tail |
| `POST` | `/marketplace/admin/upload` | X-Admin-Key | multipart `tarball` (≤50MB) + `manifest.yaml` | `{tag_created: "plugins/X/v0.2.0", render_triggered: true}` |
| `POST` | `/marketplace/admin/approve` | X-Admin-Key | `{plugin, version, decision: "approve"\|"reject"}` | `{ok, audit_id}` |
| `POST` | `/marketplace/admin/curate` | X-Admin-Key | `{plugin, action: "feature"\|"deprecate"\|"remove"}` | `{ok, audit_id}` |
| `POST` | `/marketplace/admin/rerender` | X-Admin-Key | — | `{triggered: true}` |

**错误码 mapping**（统一）：

| 错误 | HTTP code |
|---|---|
| 缺 `X-Admin-Key` header | 401（require_admin） |
| token 错误 | 403（require_admin） |
| 服务端未配置 admin_key | 503（require_admin） |
| manifest.yaml schema 不通过 | 422 |
| tag 已存在 / version 冲突 | 409 |
| SSH 通道未配置 | 503 |
| SSH 操作 timeout | 504 |
| readonly-router 拒绝命令 | 502 |

### 7.3 实现要点

- **读侧** (`/status` / `/list` / `/disk` / `/logs`)：通过 `bifrost-readonly-router.sh` 白名单调用 SSH 拉取数据。
- **写侧** (`/admin/*`)：通过独立 SSH user `bifrost-admin` 调 `bifrost-admin-router.sh`（PR-5a 产出），forced-command 白名单限于 `upload / tag-create / approve / curate / rerender`，禁止任意 shell。所有写操作记 `/var/log/marketplace/admin-audit.log`。
- **错误处理**：复用 `routers/mirrors.py:54+` 的 `_run_readonly_command` async pattern + `_probe_http` 探活。

### 7.4 单元测试要求（M15 部分覆盖）

`tests/test_marketplace_router.py` (PR-4) + `tests/test_marketplace_admin_router.py` (PR-5a) 合计 ≥250 行 pytest，覆盖：

- 401 missing header / 403 wrong header / 503 unconfigured
- 200 happy path for each GET endpoint（mock SSH 输出）
- multipart upload 大小限制（>50MB → 422）
- manifest.yaml 缺字段 → 422
- tag 冲突 → 409
- SSH 超时 → 504
- mock_router 把 admin upload chain 全部模拟一遍

---

## 8. Vue 3 SPA 架构（bifrost-api-web）

### 8.1 目录结构

```
D:/Desktop/CREATOR FIVE/
├── bifrost-api/                  (existing FastAPI)
└── bifrost-api-web/              ◀── NEW
    ├── package.json
    ├── vite.config.ts
    ├── tsconfig.json
    ├── .nvmrc                    (= "20")
    ├── index.html
    ├── src/
    │   ├── main.ts
    │   ├── App.vue
    │   ├── router/index.ts
    │   ├── stores/
    │   │   ├── auth.ts            (Pinia 3)
    │   │   └── marketplace.ts
    │   ├── api/
    │   │   ├── client.ts          (axios + X-Admin-Key interceptor)
    │   │   └── marketplace.ts     (typed wrappers)
    │   ├── views/
    │   │   ├── Login.vue
    │   │   ├── Browse.vue
    │   │   ├── PluginDetail.vue
    │   │   ├── Upload.vue
    │   │   ├── Curate.vue
    │   │   └── Status.vue
    │   ├── components/
    │   │   ├── PluginCard.vue
    │   │   ├── AdminTokenForm.vue
    │   │   └── HealthBadge.vue
    │   └── types/marketplace.ts
    ├── tests/api.spec.ts          (Vitest)
    └── dist/                      (build output → /var/www/bifrost-api-web/dist/)
```

### 8.2 package.json（N6 闭合 — 显式 `type: module` + `private: true`）

```json
{
  "name": "bifrost-api-web",
  "version": "0.1.0",
  "private": true,
  "type": "module",
  "scripts": {
    "dev": "vite",
    "build": "vue-tsc --noEmit && vite build",
    "preview": "vite preview",
    "test": "vitest run",
    "lint": "eslint src --ext .ts,.vue"
  },
  "dependencies": {
    "vue": "^3.5.0",
    "vue-router": "^4.4.0",
    "pinia": "^3.0.0",
    "axios": "^1.7.0"
  },
  "devDependencies": {
    "@vitejs/plugin-vue": "^5.0.0",
    "@types/node": "^20.0.0",
    "typescript": "^5.4.0",
    "vue-tsc": "^2.0.0",
    "vite": "^5.4.0",
    "vitest": "^1.6.0",
    "eslint": "^9.0.0"
  }
}
```

> **N3 闭合**：Pinia 升 3.x。
> **N6 闭合**：`"type": "module"` + `"private": true`。

### 8.3 路由表

```typescript
// src/router/index.ts (vue-router 4)
[
  { path: '/login',                       component: Login                                    },
  { path: '/plugins',                     component: Browse,        meta: { requiresAdmin: true } },
  { path: '/plugins/:name',               component: PluginDetail,  meta: { requiresAdmin: true } },
  { path: '/upload',                      component: Upload,        meta: { requiresAdmin: true } },
  { path: '/curate',                      component: Curate,        meta: { requiresAdmin: true } },
  { path: '/status',                      component: Status,        meta: { requiresAdmin: true } },
  { path: '/:pathMatch(.*)*',             redirect: '/plugins'                                }
]
```

`history` 模式 + Caddy `try_files {path} /index.html`（§3.2）。浏览器页面路由不得占用 `/marketplace/*`，该前缀保留给 bifrost-api JSON/TEXT API；否则生产 Caddy 反代会把页面刷新请求误送到 API。

### 8.4 Pinia auth store

```typescript
// src/stores/auth.ts
export const useAuthStore = defineStore('auth', () => {
  const adminKey = ref<string>(sessionStorage.getItem('adminKey') ?? '')
  function setKey(k: string) { adminKey.value = k; sessionStorage.setItem('adminKey', k) }
  function clear() { adminKey.value = ''; sessionStorage.removeItem('adminKey') }
  return { adminKey, setKey, clear }
})
```

### 8.5 axios client（C4 闭合）

```typescript
// src/api/client.ts
const client = axios.create({ baseURL: '/' })
client.interceptors.request.use((config) => {
  const auth = useAuthStore()
  if (auth.adminKey) {
    config.headers['X-Admin-Key'] = auth.adminKey   // ← C4: 不是 Authorization Bearer
  }
  return config
})
client.interceptors.response.use(
  r => r,
  err => {
    if (err.response?.status === 401 || err.response?.status === 403) {
      useAuthStore().clear()
      router.push('/login')
    }
    return Promise.reject(err)
  }
)
```

> **C4+M8 闭合**：仅用 `X-Admin-Key` header，**不**调 `/auth/verify`。首次受保护请求若 401/403 即视 token 无效。

### 8.6 SPA 鉴权流（M8+M9 闭合）

```
1. 用户访问 https://panel.uuhfn.cloud
   - 网络层 @panel_private 强制 vpn-first allowlist 必须先满足（M3）
   - 非 allowlist：Caddy 直接 403 "requires VPN/private access"
2. Router 守卫：sessionStorage.adminKey 为空 → /login
3. Login.vue：表单输入 admin token
4. 用户按"登录"：直接发 GET /marketplace/status（带 X-Admin-Key header）
   - 200: setKey + 跳 /marketplace
   - 401/403: 显示"token 无效"
5. 后续所有请求：axios interceptor 自动加 X-Admin-Key
6. 任何 401/403：清 store + 跳 /login
```

> **M9 闭合**：不需要 CORS（panel 和 API 同源），删除 spec v1 的 CORS 描述。
> **M8 闭合**：删除 `/auth/verify` endpoint，改用"首次受保护请求即验"。

### 8.7 CI 增量（M10 闭合 — pnpm 在 setup-node 前）

`.github/workflows/ci.yml` 新增 job：

```yaml
panel-build:
  runs-on: ubuntu-latest
  steps:
    - uses: actions/checkout@v4
    # M10: pnpm 必须在 setup-node 之前，否则 cache: pnpm 找不到 pnpm 二进制
    - uses: pnpm/action-setup@v3
      with:
        version: 9
    - uses: actions/setup-node@v4
      with:
        node-version: '20'
        cache: 'pnpm'
        cache-dependency-path: bifrost-api-web/pnpm-lock.yaml
    - run: pnpm install --frozen-lockfile
      working-directory: bifrost-api-web
    - run: pnpm lint
      working-directory: bifrost-api-web
    - run: pnpm test
      working-directory: bifrost-api-web
    - run: pnpm build
      working-directory: bifrost-api-web
    - uses: actions/upload-artifact@v4
      with:
        name: panel-dist
        path: bifrost-api-web/dist/
```

---

## 9. server-b.sh 改动规范

### 9.1 step 注入位置（精确行号锚点，与 §9.3 marketplace-render 关系图配套）

`scripts/server-b.sh:2558` `enable_distribution()` 内部 step machine：

```
Step 01_render_verdaccio       (existing, 2596)
Step 02_render_new_api         (existing, 2602)
Step 03_render_caddy           (existing, 2609) — 模板已含 §3.3 修订
Step 04_render_nftables        (existing, 2615) — 0 变更
Step 05_render_systemd         (existing, 2623) — 加 marketplace-render.{path,service} + upstream-schema-check.{timer,service}
Step 06_render_scripts         (existing, 2630) — 加 install /usr/local/bin/{render-marketplace-json.sh,check-upstream-schema.sh,bifrost-admin-router.sh}
Step 07_render_marketplace     ◀── NEW (在 06 后、08 前；2630 与 2640 之间正好有空缺步号)
Step 08_git_mirror             (existing, 2640) — 不动；bifrost-internal-plugins 不进 git-mirror 矩阵（C6）
Step 09_new_api                (existing, 2648)
Step 10_verdaccio              (existing, 2659)
Step 11_verdaccio_bootstrap    (existing, 2665)
Step 12_caddy                  (existing, 2671)
Step 13_restic                 (existing, 2678) — N1: /var/lib/dist 已被 restic backup 覆盖，无需新增
```

**step 07_render_marketplace 详细行为**（M19 闭合）：

```bash
step_id="07_render_marketplace"
if ! _distribution_step_done "${step_id}"; then
    _distribution_prepare_marketplace_dirs           # mkdir -d -o git-mirror -g git-mirror (M6)
    _distribution_init_marketplace_bare              # git init --bare + seed initial commit if 不存在
    _distribution_render_marketplace_license_notice  # 写 LICENSE / NOTICE seed 到 bare 的初始 commit
    _distribution_init_upstream_schema_baseline      # 初始化 sha256 baseline，避免首跑 false alert
    # M19: 显式 enable systemd units
    systemctl enable --now marketplace-render.path
    systemctl enable --now upstream-schema-check.timer
    # 触发一次 render 初始化 state.json
    systemctl start marketplace-render.service || true
    _distribution_mark_step_done "${step_id}"
fi
```

### 9.2 改动函数清单

| 函数 | 现状 | 改动 | LOC | PR |
|---|---|---|---|---|
| `_distribution_prepare_dirs` (server-b.sh:2266) | mkdir verdaccio/new-api/git-mirrors/dist | 不动 | 0 | — |
| `_distribution_render_caddy` (existing) | 渲染 Caddyfile-b-distribution | 模板增 `@plugins_status` 小段（§3.3） | +10（模板） | PR-2 |
| `_distribution_render_systemd_units` (existing) | render git-mirror@.{service,timer} | 增 4 个 unit 文件（path/service/timer/service） | +50 | PR-2 |
| `_distribution_render_git_mirror_script` (server-b.sh:2445) | install git-mirror-sync.sh | **C6 修复**：不加 bifrost-internal-plugins 到 case arm（保持现状即可，无需改） | 0 | — |
| `_distribution_prepare_marketplace_dirs` | 新建 | `install -d -m 0750 -o git-mirror -g git-mirror /var/log/marketplace /var/lib/dist/plugins` (M6) | ~15 | PR-2 |
| `_distribution_init_marketplace_bare` | 新建 | `git init --bare` + temp worktree initial commit (`.claude-plugin/marketplace.json` empty plugins[] + LICENSE + NOTICE) + push | ~35 | PR-2 |
| `_distribution_render_marketplace_license_notice` | 新建 | helper 输出 LICENSE/NOTICE 文本（被 _init_marketplace_bare 调用） | ~15 | PR-2 |
| `_distribution_init_upstream_schema_baseline` | 新建 | `curl + sha256sum > /etc/bifrost-api/marketplace/upstream-license-baseline.sha256` | ~10 | PR-2 |
| `_distribution_configure_admin_ssh` | 新建（同 readonly 但独立 user） | useradd bifrost-admin + 配 forced-command authorized_keys（拼 bifrost-admin-router.sh） | ~25 | PR-5a |
| `_distribution_verify` (server-b.sh:2523) | 现有验证 | 加 3 项：marketplace.json 在 bare HEAD 可见、`systemctl is-active marketplace-render.path`、`/var/lib/dist/plugins/state.json` 存在 | +25 | PR-2 |

### 9.3 marketplace × git-mirror systemd 关系图（C6+M1+M16+M19 闭合）

```
                  ┌───────────────────────────────────────────────┐
                  │  Existing (0519-1)                            │
                  │  git-mirror@claude-for-legal-zh.timer (02:00)  │
                  │   └─> git-mirror-sync.sh claude-for-legal-zh   │
                  │        └─> 从 GitHub 拉 → bare → archive 到 dist│
                  └───────────────────────────────────────────────┘

                  ┌───────────────────────────────────────────────┐
                  │  NEW (本任务)                                  │
                  │  bifrost-internal-plugins.git                  │
                  │  (NOT in git-mirror-sync matrix; C6 闭合)     │
                  │                                                │
                  │  Trigger 1 (主路径)：                          │
                  │    panel.uuhfn.cloud /marketplace/admin/upload │
                  │      → SSH bifrost-admin@10.8.0.2              │
                  │      → bifrost-admin-router.sh upload          │
                  │      → git clone bare to /tmp/work             │
                  │      → cp + commit + tag + push                │
                  │      → bare/packed-refs CHANGE                 │
                  │      → marketplace-render.path INOTIFY         │
                  │      → marketplace-render.service ONESHOT      │
                  │      → render-marketplace-json.sh              │
                  │           → clone bare to /tmp/render          │
                  │           → write .claude-plugin/marketplace.json│
                  │           → commit + push back to bare         │
                  │           → write /var/lib/dist/plugins/state.json│
                  │      → bare/HEAD updated                       │
                  │                                                │
                  │  Trigger 2 (探活路径)：                        │
                  │    upstream-schema-check.timer (daily)         │
                  │      → check-upstream-schema.sh                │
                  │      → 写 state.json.upstream_alert            │
                  │      （不写 git tree）                          │
                  │                                                │
                  │  M1: 无 git-mirror@bifrost-internal-plugins.timer│
                  │      (因为 bare 自含权威源，无 upstream 可拉)  │
                  │  M16: bifrost-readonly-router.sh 在 logs:git-  │
                  │      mirror 内层 allowlist 加 bifrost-internal-│
                  │      plugins，**不**新增独立 arm                │
                  │  M19: step 07 末尾显式 systemctl enable --now  │
                  │      marketplace-render.path                    │
                  │      upstream-schema-check.timer                │
                  └───────────────────────────────────────────────┘
```

### 9.4 disable_distribution 改动（M12 闭合）

**追加 3 行到现有 disable 段**（server-b.sh:2697 后），**不重复**现有 git-mirror@claude-for-legal-zh 的 disable：

```bash
disable_distribution() {
    log_info "=========================================="
    log_info "  Disabling Server B Private Distribution"
    log_info "=========================================="

    # M12: 现有行已存在，本任务只追加以下 3 行
    systemctl disable --now marketplace-render.path 2>/dev/null || true
    systemctl disable --now upstream-schema-check.timer 2>/dev/null || true
    # marketplace-render.service 是 oneshot，无需单独 disable

    # ... 后续是 0519-1 已有的 disable 命令（不重写）
}
```

---

## 10. PR 拆分计划（v2：8 个 PR，PR-1b deferred；PR-5 拆 5a+5b）

### 10.1 PR 依赖图（M13 闭合 — fork-join）

```
PR-1 (skeleton + render script + sample plugin)
  │
  └──► PR-2 (server-b.sh step 07 + B Caddy + systemd units)
         │
         └──► PR-3 (A Caddy panel + vpn-first allowlist + DNS docs)
                │
                └──► PR-4 (bifrost-api /marketplace read routes)
                       │
                       ├──► PR-5a (admin write routes + SSH channel + tests)
                       │      │
                       │      └──► PR-5b (Vue SPA + CI + deploy script) ─┐
                       │                                                  │
                       └──► PR-6 (team settings template + seed dir) ────┤
                                                                          │
                                                                          ▼
                                                                       PR-7 (docs + E2E + check-upstream-schema.sh)

PR-1b deferred (BLOCKED-on-LICENSE — ADR-4 DENY)
```

> **M13 闭合**：PR-6 与 PR-5a/5b 并行（PR-6 仅依赖 PR-1..PR-4）；PR-7 等所有上游完成。
> **M14 闭合**：PR-3 显式声明外部依赖 `external: 05-19-server-a-hardening-v2#PR-3 merged-to-main`。

### 10.2 PR 详表

#### PR-1: monorepo skeleton + render-marketplace-json.sh + 1 sample plugin

**Scope**:
- `prompts/0519-1/marketplace-bootstrap/bifrost-internal-plugins/` 初始 seed：
  - **`.claude-plugin/marketplace.json`**（N4 闭合 — 与 §4.1 schema 完全一致，含 1 sample plugin）
  - `LICENSE`, `NOTICE`, `README.md`, `.gitignore`
  - `plugins/hello-world-skill/.claude-plugin/plugin.json`
  - `plugins/hello-world-skill/manifest.yaml`
  - `plugins/hello-world-skill/skills/hello/SKILL.md`
  - `plugins/hello-world-skill/LICENSE`, `plugins/hello-world-skill/README.md`
- `scripts/render-marketplace-json.sh`（§4.2 实现，~250 行 bash）
- `scripts/validate-marketplace-schema.sh`（CI 用，~80 行）
- `tests/test-render-marketplace.sh`（docker-in-docker E2E）

**Dependencies**: 无

**Exit Criteria**:
- 本地 `bash scripts/render-marketplace-json.sh bifrost-internal-plugins <fake-bare>` 产生合规 `.claude-plugin/marketplace.json`，schema 通过 `validate-marketplace-schema.sh`
- `claude plugin validate ./bifrost-internal-plugins` (官方 CLI) 输出 OK（如 CI 可装 claude）

**LOC**: ~400~500

---

#### PR-1b: 官方 mirror（**deferred / BLOCKED-on-LICENSE**）

Status: 不进 MVP。Trigger: `check-upstream-schema.sh` 检测到上游变 OSS license。

---

#### PR-2: server-b.sh step 07 + B Caddy + systemd units + admin-router 框架

**Scope**:
- `scripts/server-b.sh` 新增函数（§9.2 列表）+ step 07 注入（§9.1）
- `configs/caddy/Caddyfile-b-distribution.tpl:9-19` 改成 §3.3 渲染目标
- `configs/systemd/marketplace-render.path`, `marketplace-render.service`, `upstream-schema-check.timer`, `upstream-schema-check.service` 新建（§4.3）
- `_distribution_render_systemd_units` 渲染新 units
- `scripts/server-b.sh _distribution_render_git_mirror_script` **不改动**（C6）
- `scripts/bifrost-readonly-router.sh` 扩展（M16）：在现有 `logs:git-mirror` arm 内层 allowlist 加 `bifrost-internal-plugins`；并新增 case arms `marketplace:status` / `marketplace:list-json` / `marketplace:disk-report` / `logs:marketplace-render` / `logs:upstream-schema-check`

**Dependencies**: PR-1

**Exit Criteria**:
- 干净 VM 上 `bash scripts/server-b.sh --enable-distribution` 跑两次都成功，第二次秒级
- `systemctl is-active marketplace-render.path upstream-schema-check.timer` 都 active
- `tests/test-in-docker.sh` parity check 通过

**LOC**: ~500~600

---

#### PR-3: Server A Caddy `panel.uuhfn.cloud` + vpn-first allowlist + DNS 文档

**Scope**:
- `configs/caddy/Caddyfile-a.tpl:286+` 追加 §3.2 `panel.{{DOMAIN}}` 站点（含 `@panel_private remote_ip {{ADMIN_ALLOWED_RANGES}}`，M3 闭合）
- `scripts/server-a.sh` inline Caddyfile 渲染分支同步
- DNS 步骤说明（写到 docs/USAGE.md，PR-7 完成 — 但 PR-3 内 README 文档级提示）

**Dependencies**: PR-2 + **external: 05-19-server-a-hardening-v2#PR-3 merged-to-main**（M14 闭合，因为 `{{ADMIN_ALLOWED_RANGES}}` template var 来自 hardening-v2）

**Exit Criteria**:
- `nmap -p- <A_PUB_IP>` 输出与 baseline 完全一致（**无新端口**）
- `git ls-remote https://files.uuhfn.cloud/git/bifrost-internal-plugins.git` 在 LAN 内成功
- `curl -I https://panel.uuhfn.cloud/` 在 allowlist 内 200，allowlist 外 403

**LOC**: ~200~300

---

#### PR-4: bifrost-api `/marketplace/*` 只读路由

**Scope**:
- `bifrost-api/app/routers/marketplace.py` 新建（§7.2 read endpoints，~250 行）
- `bifrost-api/app/main.py:128` 后 `app.include_router(marketplace_router.router)`
- `tests/test_marketplace_router.py`（~150 行 pytest，§7.4 read 部分）
- `scripts/bifrost-readonly-router.sh` 在 PR-2 已加 case arms 基础上微调（如需）

**Dependencies**: PR-2, PR-3

**Exit Criteria**:
- `curl -H "X-Admin-Key: $K" https://panel.uuhfn.cloud/marketplace/status` 200 返 JSON（含 `last_render_ts`, `upstream_alert`）
- pytest 全绿

**LOC**: ~400~500

---

#### PR-5a: admin 写路由 + bifrost-admin-router.sh + 独立 SSH 通道 + 后端测试（M11 闭合）

**Scope**:
- `bifrost-api/app/routers/marketplace_admin.py` 新建（§7.2 write endpoints，~280 行）
- `scripts/bifrost-admin-router.sh` 新建（forced-command 白名单 + audit log，~100 行）
- `scripts/server-b.sh _distribution_configure_admin_ssh` 新建（§9.2 ~25 行）
- `_distribution_render_caddy` 不动（panel 已在 PR-3）
- `tests/test_marketplace_admin_router.py`（~150 行 pytest，§7.4 write 部分）

**Dependencies**: PR-4

**Exit Criteria**:
- `curl -X POST -F "tarball=@..." -F "manifest=@..." -H "X-Admin-Key: $K" https://panel.uuhfn.cloud/marketplace/admin/upload` 成功，bare 内出现新 tag，marketplace.json `git_head_sha` 更新
- audit log 写入正确

**LOC**: ~580

---

#### PR-5b: Vue 3 SPA + CI workflow + deploy script

**Scope**:
- `bifrost-api-web/` 整个目录（§8.1，~500 行 TS/Vue + ~50 行测试）
- `.github/workflows/ci.yml` 新增 `panel-build` job（§8.7，~30 行）
- `scripts/server-a.sh --deploy-panel` 子命令（拷 `dist/` 到 `/var/www/bifrost-api-web/dist/`，~60 行）

**Dependencies**: PR-5a

**Exit Criteria**:
- 浏览器在 allowlist 内访问 https://panel.uuhfn.cloud → 登录 → /marketplace 列出 plugin
- CI `panel-build` job 通过
- E2E：手动 upload sample plugin 成功

**LOC**: ~590

---

#### PR-6: 团队 settings template + onboarding seed dir（M13: 与 PR-5a/5b 并行）

**Scope**:
- `prompts/0519-1/team-config/.claude/settings.json.template`（含 `extraKnownMarketplaces.bifrost-internal` + `enabledPlugins` + `permissions.deny`）
  - 注意：`source` 字段用 `{source: "url", url: "https://files.uuhfn.cloud/git/bifrost-internal-plugins.git"}`（C3 闭合：无 `git+` 前缀）
- `prompts/0519-1/team-config/CLAUDE.md.template`
- `scripts/build-marketplace-seed.sh`（生成 `CLAUDE_CODE_PLUGIN_SEED_DIR` 离线包 tarball，~80 行）
- `prompts/0519-1/marketplace-bootstrap/seed/README.md`（onboarding 指南）

**Dependencies**: PR-1..PR-4（不依赖 PR-5）

**Exit Criteria**:
- 干净笔记本：拷 settings template + `CLAUDE_CODE_PLUGIN_SEED_DIR=/tmp/seed` 启动 claude → `/plugin browse` 看到 hello-world-skill
- seed tarball sha256 校验通过

**LOC**: ~200~300

---

#### PR-7: docs + E2E rehearsal + check-upstream-schema.sh

**Scope**:
- `docs/USAGE.md:589` 后追加 `### Server B 内部 Claude marketplace` 章节（含 DNS 添加步骤、admin 上传 SOP、版本回退、`CLAUDE_CODE_PLUGIN_SEED_DIR` 用法）
- `docs/SECURITY.md:97` 后追加 `### Server B 内部 Claude marketplace 安全边界` 章节（含 `@panel_private` 解释、`X-Admin-Key` 轮换 SOP、ADR-4 引用、`permissions.deny` 设计）
- `scripts/e2e-distribution-rehearsal.sh` 扩展（M15 闭合 — 含 AC-1 baseline 生成 + AC-4/AC-9/AC-10 可脚本化验证）
- `scripts/check-upstream-schema.sh` 新建（§5.4 完整实现）

**Dependencies**: PR-1..PR-6

**Exit Criteria**:
- `bash scripts/e2e-distribution-rehearsal.sh` 完整通过，含 marketplace 段
- AC-1..AC-14 全部勾选

**LOC**: ~350~450

---

## 11. 验收测试矩阵（M15 闭合 — 全部可脚本化）

| AC | 描述 | 验证命令 | PR |
|---|---|---|---|
| **AC-1** | nmap baseline 不变 | **Baseline 产生**：PR-2 deploy 前在 rehearsal 脚本中执行 `nmap -p- <B_PUB_IP> > /var/lib/bifrost/baseline/nmap-b-pre.txt`<br>**验证**：deploy 后 `nmap -p- <B_PUB_IP> > /tmp/nmap-after.txt && diff /var/lib/bifrost/baseline/nmap-b-pre.txt /tmp/nmap-after.txt` 退出码 0 | PR-3 (rehearsal in PR-7) |
| **AC-2** | marketplace.json 在 git tree 内可读 | `git clone https://files.uuhfn.cloud/git/bifrost-internal-plugins.git /tmp/test-clone && jq -r .name /tmp/test-clone/.claude-plugin/marketplace.json` 等于 `"bifrost-internal"` | PR-3 |
| **AC-3** | git ls-remote 成功 | `git ls-remote https://files.uuhfn.cloud/git/bifrost-internal-plugins.git refs/heads/main` 返回非空（无 `git+` 前缀 — C3） | PR-3 |
| **AC-4** | `extraKnownMarketplaces` 设置已下发（替代 TUI 交互） | `jq -e '.extraKnownMarketplaces["bifrost-internal"].source.url' ~/.claude/settings.json` 输出 `"https://files.uuhfn.cloud/git/bifrost-internal-plugins.git"` | PR-6 (rehearsal PR-7) |
| **AC-5** | `/plugin install` 落盘 | `claude --headless plugin install hello-world-skill@bifrost-internal && test -d ~/.claude/plugins/cache/bifrost-internal/hello-world-skill/v0.1.0/` | PR-7 |
| **AC-6** | 版本回退 | 安装 v0.2.0 后：`claude --headless plugin install hello-world-skill@bifrost-internal --version v0.1.0` 落到 `v0.1.0/` | PR-7 |
| **AC-7** | server-b.sh idempotent | 跑 `--enable-distribution` 两次，第二次 step 07 < 1s | PR-2 |
| **AC-8** | bifrost-api `/marketplace/status` admin-gated | 无 header → 401；`curl -H "X-Admin-Key: wrong" https://panel.uuhfn.cloud/marketplace/status` → 403；正确 header → 200 + JSON 含 `last_render_ts` | PR-4 |
| **AC-9** | SPA list API 可调 | `curl -H "X-Admin-Key: $K" https://panel.uuhfn.cloud/marketplace/list \| jq '.plugins \| length'` ≥ 1 | PR-4 |
| **AC-10** | Admin upload 触发 render | `curl -X POST -H "X-Admin-Key: $K" -F "tarball=@hello-v0.2.0.tar.gz" -F "manifest=@manifest.yaml" https://panel.uuhfn.cloud/marketplace/admin/upload \| jq -e .tag_created` 非空；接着 `git -C /var/lib/git-mirrors/bifrost-internal-plugins.git tag --list "plugins/hello-world-skill/v0.2.0"` 非空 | PR-5a |
| **AC-11** | LICENSE / NOTICE 输出 | `git clone .../bifrost-internal-plugins.git /tmp/c && test -f /tmp/c/LICENSE && test -f /tmp/c/NOTICE && grep -q "ALL-RIGHTS-RESERVED" /tmp/c/LICENSE` | PR-2 |
| **AC-12** | **LICENSE fallback path** (C5 闭合) | `bash /usr/local/bin/check-upstream-schema.sh` + `journalctl -u upstream-schema-check.service -n 20 \| grep -E "^(LICENSE-OK\|LICENSE-BASELINE-INIT\|UPSTREAM-CHANGED) [0-9a-f]{64}" \| head -1` 必须有输出；`jq -e '.upstream_alert == false' /var/lib/dist/plugins/state.json` 退出 0 | PR-7 |
| **AC-13** | DNS + panel 域名 | `dig +short panel.uuhfn.cloud` 返回 A 公网 IP；allowlist 内 `curl -I https://panel.uuhfn.cloud/` 200；allowlist 外 403 | PR-3 |
| **AC-14** | docs 完整 | `grep -q "## Server B 内部 Claude marketplace" docs/USAGE.md`；`grep -q "## Server B 内部 Claude marketplace 安全边界" docs/SECURITY.md`；`bash scripts/e2e-distribution-rehearsal.sh` 退出码 0 | PR-7 |

---

## 12. 风险登记簿

| # | 风险 | 概率 | 影响 | 缓解 | 触发 PR |
|---|---|---|---|---|---|
| RK-1 | Anthropic 升级 marketplace 协议 | 中 | 高 | upstream-schema-check.timer 监控；docs 标 min Claude Code 版本 | PR-7 |
| RK-2 | 恶意 plugin hook 提权 | 低 | 极高 | `permissions.deny` 兜底；admin upload + audit log；panel curate review | PR-6 |
| RK-3 | Vue / Node CI 矩阵复杂度上升 | 中 | 中 | 独立 `panel-build` job 不阻塞 Python CI；pnpm@9 + Node 20 LTS 锁定 | PR-5b |
| RK-4 | `panel.uuhfn.cloud` 公网 token 爆破 | 已闭合 | — | M3 修复 — `@panel_private remote_ip` 强制 vpn-first，非 allowlist 直接 403 | PR-3 |
| RK-5 | LICENSE 合规误判（误 mirror 上游） | 低 | 极高 | ADR-4 LOCKED + check-upstream-schema.sh + 强制 LICENSE/NOTICE 输出 | PR-2, PR-7 |
| RK-6 | marketplace.json render 失败 | 中 | 高 | render 脚本 `git diff --quiet` 检查 + 失败不 commit；state.json `last_render_ts` 暴露 | PR-2 |
| RK-7 | tag 命名错误 | 中 | 中 | render exit 3 + validate-marketplace-schema.sh CI lint | PR-1 |
| RK-8 | admin/readonly SSH 通道权限混淆 | 低 | 高 | 两 user (`bifrost-readonly`/`bifrost-admin`) + 两 forced-command 脚本 + audit log | PR-5a |
| RK-9 | `/var/lib/git-mirrors/.../packed-refs` 由 git gc 触发死循环 render | 低 | 低 | render 脚本 `git diff --quiet` 检查；packed-refs 无内容变化时 commit 跳过 | PR-2 |
| RK-10 | 与 hardening-v2 PR-3 合并冲突 | 中 | 低 | PR-3 显式声明 external 依赖（M14） | PR-3 |
| RK-11 | DNS panel.uuhfn.cloud 未及时配置 | 中 | 低 | PR-3 docs 含 DNS 步骤；AC-13 显式验证 | PR-3 |
| RK-12 | C6 自指 upstream 死锁 | 已闭合 | — | bifrost-internal-plugins **不进** git-mirror-sync 矩阵，仅由 panel admin upload + marketplace-render.path 触发 | — |
| RK-13 | marketplace-render 写 git tree 时被并发 admin upload 抢占 | 低 | 中 | git push 失败时 service exit 4，下次 path-trigger 自动重跑；`git pull --rebase` 在 render 脚本内尝试一次 | PR-2 |
| RK-14 | `state.json` 被多个 service 并发写 | 低 | 低 | 使用临时文件 + `mv` 原子替换 | PR-2 |

---

## 13. 关联任务协同图

```
                ┌─────────────────────────────────────────┐
                │ 05-19-server-a-hardening-v2 PR-3        │
                │ (in_progress, 必须 merged-to-main 才能  │
                │  启动本任务 PR-3)                       │
                └────────────────┬────────────────────────┘
                                 │ external dep
                                 ▼
   ┌──────────────────────────────────────────────────────┐
   │ 05-19-server-b-private-distribution (DELIVERED)     │
   │ Caddy 8081/8082 + fcgiwrap + git-mirror + readonly-router│
   └────────────────────────┬─────────────────────────────┘
                            │ 直接复用
                            ▼
   ┌──────────────────────────────────────────────────────┐
   │ 本任务（design-frozen v2）                            │
   │ PR-1 ▸ PR-2 ▸ PR-3 ▸ PR-4 ▸ PR-5a ▸ PR-5b ▸ PR-7   │
   │                                       PR-6 ─────▶◀  │
   │                                                       │
   │ PR-1b deferred (BLOCKED-on-LICENSE)                   │
   └──────────────────────────────────────────────────────┘

   并行任务：
   - 05-19-0519-1-improvement (in_progress; 改 readonly-router 时 rebase 协调)
   - 05-18-newapi-uuhfn-cloud-package (完全解耦)
```

---

## 14. GitNexus 影响分析 stub（implement 阶段必跑）

```bash
# Before PR-2
gitnexus_impact({target: "enable_distribution", direction: "upstream"})
gitnexus_context({name: "_distribution_render_systemd_units"})
gitnexus_context({name: "_distribution_render_caddy"})
gitnexus_context({name: "_distribution_mark_step_done"})
gitnexus_context({name: "_distribution_prepare_dirs"})

# Before PR-3
gitnexus_impact({target: "setup_caddy_a", direction: "upstream"})

# Before PR-4
gitnexus_context({name: "require_admin"})
gitnexus_context({name: "_run_readonly_command"})
gitnexus_context({name: "_probe_http"})

# Before PR-5a
gitnexus_impact({target: "include_router", direction: "upstream"})
gitnexus_context({name: "_distribution_configure_readonly_ssh"})  # 模仿其结构写 admin 版

# Each PR commit
gitnexus_detect_changes({scope: "staged"})
```

---

## 15. Definition of Done

- AC-1..AC-14 全部勾选（含 AC-12 LICENSE fallback C5 闭合）
- PR-1..PR-7（7 个 active）合入 main；PR-1b 标 deferred / BLOCKED
- spec-review.md 31 findings 全部 closed（spec v2 banner 标明 6C+19M+6N 闭合数）
- `tests/test-in-docker.sh` parity 通过
- `bifrost-api-web` CI `panel-build` job 通过
- `docs/USAGE.md` + `docs/SECURITY.md` 新章节落地
- ADR-1..ADR-4 在 prd.md 中 LOCKED
- 至少 1 名团队成员从干净笔记本完成 `/plugin marketplace add` → `/plugin install` 全流程
- agent manager 通过 `panel.uuhfn.cloud` 完成至少 1 次 upload + curate
- `gitnexus_impact` + `gitnexus_detect_changes` 在每 PR 前后跑

---

## 16. 关键命令附录

```bash
# === 部署 ===
bash scripts/server-b.sh --enable-distribution      # 含 step 07
bash scripts/server-a.sh --enable-distribution      # 加 panel.uuhfn.cloud 站点
bash scripts/server-a.sh --deploy-panel             # 拷 bifrost-api-web/dist → /var/www/

# === 验收（C4 闭合：全部用 X-Admin-Key，非 Bearer）===
nmap -p- <SERVER_B_PUBLIC_IP>                       # AC-1
git clone https://files.uuhfn.cloud/git/bifrost-internal-plugins.git /tmp/c   # AC-2 (C3: 无 git+)
jq .name /tmp/c/.claude-plugin/marketplace.json     # AC-2
curl -H "X-Admin-Key: $BIFROST_ADMIN_KEY" https://panel.uuhfn.cloud/marketplace/status   # AC-8
curl -H "X-Admin-Key: $BIFROST_ADMIN_KEY" https://panel.uuhfn.cloud/marketplace/list | jq '.plugins | length'   # AC-9
curl -X POST -H "X-Admin-Key: $BIFROST_ADMIN_KEY" \
  -F "tarball=@hello-v0.2.0.tar.gz" \
  -F "manifest=@manifest.yaml" \
  https://panel.uuhfn.cloud/marketplace/admin/upload  # AC-10
bash /usr/local/bin/check-upstream-schema.sh        # AC-12
jq -e '.upstream_alert == false' /var/lib/dist/plugins/state.json   # AC-12

# === 团队成员（无 git+ 前缀 — C3）===
# 推荐：通过项目 .claude/settings.json 自动注入 extraKnownMarketplaces，0 手动
# 或手动：
claude plugin marketplace add https://files.uuhfn.cloud/git/bifrost-internal-plugins.git
claude plugin install hello-world-skill@bifrost-internal

# === Agent manager (admin) ===
# 浏览器 (在 VPN/allowlist 网段内)：https://panel.uuhfn.cloud
# curl 等效：
curl -X POST -H "X-Admin-Key: $BIFROST_ADMIN_KEY" \
  -F "tarball=@plugin.tar.gz" -F "manifest=@manifest.yaml" \
  https://panel.uuhfn.cloud/marketplace/admin/upload

curl -X POST -H "X-Admin-Key: $BIFROST_ADMIN_KEY" \
  -H "Content-Type: application/json" \
  -d '{"plugin":"hello-world-skill","action":"feature"}' \
  https://panel.uuhfn.cloud/marketplace/admin/curate

# === 调试 ===
systemctl status marketplace-render.path
systemctl status upstream-schema-check.timer
journalctl -u marketplace-render.service -n 100
journalctl -u upstream-schema-check.service -n 50
ssh -i ~/.ssh/bifrost-readonly bifrost-readonly@10.8.0.2 'marketplace:status'
ssh -i ~/.ssh/bifrost-readonly bifrost-readonly@10.8.0.2 'logs:marketplace-render'

# === 应急 ===
systemctl start marketplace-render.service          # 手动 re-render
bash /usr/local/bin/render-marketplace-json.sh bifrost-internal-plugins \
    /var/lib/git-mirrors/bifrost-internal-plugins.git   # 本地直跑

# === 回滚 ===
bash scripts/server-b.sh --disable-distribution
# 或仅 disable marketplace：
systemctl disable --now marketplace-render.path upstream-schema-check.timer
```

---

## 17. v1 → v2 变更摘要

| 变更类型 | 章节 | 行号 | v1 | v2 |
|---|---|---|---|---|
| Critical fix C1 | §0.2 §4 §6.1 §9.1 | 多处 | marketplace.json 落 `/var/lib/dist/plugins/marketplace.json` sidecar | **git tree `.claude-plugin/marketplace.json`**，worktree→commit→push |
| Critical fix C2 | §4.1 | 279 | `"owner": "bifrost-team"` (string) | `"owner": {"name": "Bifrost Team", "email": "..."}` (**object**) |
| Critical fix C2 | §4.1 | 297 | `"source": {"type": "git-subdir", ...}` | `"source": "./plugins/<name>"` (relative path string) |
| Critical fix C3 | §0.1 §6.3 §11 §16 | 多处 | `git+https://...` 前缀 | bare `https://files.uuhfn.cloud/git/.../.git` |
| Critical fix C4 | §7 §8.5 §8.6 §16 | 多处 | `Authorization: Bearer ${token}` | `X-Admin-Key: ${token}` (与 dependencies.py:40 一致) |
| Critical fix C5 | §11 AC-12 | 1003 | "exits 0 + journals 'no change'" 不可测 | 具体 grep regex + `jq .upstream_alert state.json == false` |
| Critical fix C6 | §9.1 §9.3 | 786-802 | `bifrost-internal-plugins` 加入 git-mirror-sync 矩阵 (自指死锁) | **不进**矩阵；仅 panel + path unit 双触发 |
| Major M1 | §9.3 | 802 | 30 分钟 cadence | 不需独立 timer；render 走 path unit |
| Major M2 | §3.2 | 215+ | API 反代缺 `header_up` | 加 4 项 + `transport http { dial_timeout 5s }` |
| Major M3 | §3.2 §1.3 | 202-228 | panel.uuhfn.cloud 仅 token 防护 | **强制** `@panel_private remote_ip {{ADMIN_ALLOWED_RANGES}}` |
| Major M4 | §3.1 §3.2 | 166 169 | `/plugins/*` proxy 缺 transport | 加 `dial_timeout 5s` |
| Major M5 | §4.3 | 355-362 | `PathChanged=` | `PathModified=` |
| Major M6 | §9.2 §4.3 | 760 | `/var/log/marketplace` 无 owner | `install -d -o git-mirror -g git-mirror` |
| Major M7 | §4.3 | 470-477 | 缺 network-online.target | 加 Requires/After |
| Major M8 | §7 §8.6 | 725 729 | `/auth/verify` endpoint | 删除；首次受保护请求 200/401 即验 |
| Major M9 | §8.6 | 729 | CORS 配置 | 删除（同源） |
| Major M10 | §8.7 | 705 | setup-node 后 corepack pnpm | `pnpm/action-setup@v3` 在 setup-node 前 |
| Major M11 | §10 PR-5 → 5a/5b | 全 | PR-5 单 PR ~1170-1370 LOC | 拆 5a (~580) + 5b (~590) |
| Major M12 | §9.4 | 807-815 | disable 段重复 existing 行 | 仅追加 3 行 |
| Major M13 | §10 图 | 822 | PR-5→6→7 串行 | fork-join: 5a→5b 与 6 并行→7 |
| Major M14 | §10 PR-3 | — | RK-10 备注 | 显式 `external: hardening-v2#PR-3 merged-to-main` |
| Major M15 | §11 | 992 995 1000 1001 | AC-1/4/9/10 含 manual 步骤 | 全部脚本化 |
| Major M16 | §9.2 | 586 | 新增独立 `logs:git-mirror-bifrost-internal-plugins` arm | 扩展 existing `logs:git-mirror` 内层 allowlist |
| Major M17 | §6.3 | 535 531 | 模糊 PR flow | 明确 panel admin upload；dev 不直接 push |
| Major M18 | §4.2 | 340 | atomic mv 到 dist sidecar | git worktree→add→commit→push→state.json |
| Major M19 | §9.1 §4.3 | 733 743-745 | step 07 未 enable systemd | step 07 末尾显式 enable path + timer |
| Minor N1 | §9.1 | 752 | step 13 加 plugins 到 restic | 删除（已 cover） |
| Minor N2 | §1.1 | 128 | panel 进程行复杂 | 简化 |
| Minor N3 | §8.2 | 687 | `pinia@2` | `pinia@3` |
| Minor N4 | §6.1 | 507-509 | 缺 `.claude-plugin/marketplace.json` 节点 | 已补 |
| Minor N5 | §1.3 §3.2 | 149 202 | panel auth matrix vs Caddy 不一致 | 通过 M3 修复对齐 |
| Minor N6 | §8.2 | 683 | 缺 `type: module` / `private: true` | 已补 |

**统计**：6 Critical 全闭合（C1-C6），19 Major 全闭合（M1-M19），6 Minor 全闭合（N1-N6）。**总闭合率 31/31 = 100%**。

---

> **下一步**：spec v2 → reviewer 再走一轮（可选）→ implement 阶段 PR-1 启动。
