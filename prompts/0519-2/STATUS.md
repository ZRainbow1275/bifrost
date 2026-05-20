# Server B 内部 Claude artifacts marketplace + visual panel — STATUS

> **Snapshot taken**: 2026-05-20
> **Trellis task path**: `.trellis/tasks/05-19-server-b-claude-artifacts-marketplace-visual-panel/`
> **Branch**: `main` @ `c0d3f52` (pushed to origin)
> **Phase**: `mvp-delivered-2026-05-20`

## 1. Quick summary

Bifrost server-b 内部 Claude artifacts marketplace + visual panel 任务 7/8 PR 闭环交付（10 commits 累积，已 push origin/main `5edf057..c0d3f52`）。**2 个 PR deferred**（PR-3 外部依赖 + PR-5b 联调依赖），**1 个 PR-1b 永久 deferred**（ADR-4 LICENSE LOCKED）。

8/14 AC scripted PASS，6/14 AC SKIP（待 PR-3 + PR-5b 解锁）。

## 2. 已交付 PR 清单

| PR | Commit | LOC | 交付物 |
|---|---|---|---|
| **0519-1 base** | `77be63d` | ~11573 | Server B 私有分发栈（0519-1 完整交付，含 PR-2 共享文件改动） |
| **PR-1** | `2cb8d57` | ~1854 | `prompts/0519-1/marketplace-bootstrap/bifrost-internal-plugins/` 整目录 + `scripts/render-marketplace-json.sh` (398 行) + `scripts/validate-marketplace-schema.sh` (173 行) + `tests/test-render-marketplace.sh` (235 行) |
| **PR-2** | `9c6dbfe` | ~636 (独立) + 共享文件 (~440) | `configs/systemd/marketplace-render.{path,service}` + `configs/systemd/upstream-schema-check.{timer,service}` + `scripts/check-upstream-schema.sh` (102 行); 共享文件改动在 base commit |
| **PR-4** | `7e63352` | ~755 | `bifrost-api/app/routers/marketplace.py` (274 行 + 4 GET endpoints) + `bifrost-api/tests/conftest.py` + `bifrost-api/tests/test_marketplace_router.py` (428 行, 34 cases PASS) + `bifrost-api/app/main.py` +4 行 |
| **PR-5a** | `cd9be42` | ~1341 | `bifrost-api/app/routers/marketplace_admin.py` (419 行 + 4 POST endpoints) + `scripts/bifrost-admin-router.sh` (233 行 forced-command 5-verb) + `scripts/server-b.sh` +78 行 (含 `_distribution_configure_admin_ssh`) + `bifrost-api/app/config.py` +8 字段 + tests (552 行, 32 cases PASS) + `tests/test-in-docker.sh` +44 行 |
| **PR-6** | `2c66ba9` | ~475 | `prompts/0519-1/team-config/.claude/settings.json.template` (34 行, 12 条 permissions.deny) + `prompts/0519-1/team-config/CLAUDE.md.template` (97 行) + `scripts/build-marketplace-seed.sh` (156 行, reproducible sha256) + `prompts/0519-1/marketplace-bootstrap/seed/README.md` (184 行) + `.gitignore` +4 negation |
| **PR-7** | `c0d3f52` | ~574 | `docs/USAGE.md` +189 行 marketplace 章节 + `docs/SECURITY.md` +141 行安全边界 + `scripts/e2e-distribution-rehearsal.sh` 62→280 行 (含 marketplace AC 段) + `scripts/check-upstream-schema.sh` +14/-10 行 Windows Git Bash 兼容 |

## 3. 部署联调修复 chore commits

| Commit | 说明 |
|---|---|
| `52b6ad6` | `chore(0519-1): include claude-for-legal-mirror Caddyfile (missed in 77be63d)` |
| `5beb2b8` | `chore(0519-1): Windows VPS marketplace deploy fixups` (Caddyfile /git/* 路由 + setup-marketplace-vps.ps1 ErrorActionPreference Stop→Continue) |
| `5a19a9a` | `chore(0519-1): Windows VPS DEPLOY.md fixups (HEAD branch + PS 5.1 compat)` (master→main + SkipHttpErrorCheck 注释 + 标点) |

## 4. Deferred PRs (3 个)

### PR-1b: mirror anthropic/claude-code (**永久 deferred**)

- **Blocker**: ADR-4 LOCKED via WebFetch — anthropic/claude-code `LICENSE.md` = `© Anthropic PBC. All rights reserved.` + Anthropic Commercial ToS D.4/F 无 redistribution 授权
- **Unlock condition**: Anthropic 改 OSS license（MIT/Apache-2.0/etc.）
- **Monitor**: `scripts/check-upstream-schema.sh` 每日 cron 监测 sha256 drift；`UPSTREAM-CHANGED` 状态码触发 agent manager 介入
- **Status snapshot**: `state.json.upstream_alert=false`, baseline sha256 已在 server-b deploy 时初始化

### PR-3: Server A `panel.uuhfn.cloud` Caddy + vpn-first allowlist + DNS 文档 (**BLOCKED on external**)

- **Blocker**: 外部任务 `05-19-server-a-hardening-v2#PR-3 merged-to-main` 未满足
  - `{{ADMIN_ALLOWED_RANGES}}` template var 来自 hardening-v2
  - `05-19-server-a-hardening-v2` 当前 status=`in_progress`
- **Spec scope**: 
  - `configs/caddy/Caddyfile-a.tpl:286+` 追加 `panel.{{DOMAIN}}` 站点（含 `@panel_private remote_ip {{ADMIN_ALLOWED_RANGES}}` M3 闭合 vpn-first）
  - `scripts/server-a.sh` inline Caddyfile 渲染分支同步
  - DNS 步骤说明（已在 PR-7 docs/USAGE.md placeholder）
- **LOC**: ~200-300
- **Unlock AC**: AC-2, AC-3, AC-13

### PR-5b: Vue 3 SPA + CI workflow + deploy script (**NOT STARTED**)

- **Why not started**: SPA E2E 联调需 `panel.uuhfn.cloud` 真实部署 (PR-3 dep)；后端 logic 实际可独立写
- **Spec scope**:
  - `bifrost-api-web/` 整目录 (~500 行 TS/Vue + ~50 行测试)
  - `.github/workflows/ci.yml` 新增 `panel-build` job (~30 行 pnpm@9 + Node 20 LTS 锁定)
  - `scripts/server-a.sh --deploy-panel` 子命令 (~60 行, 拷 `dist/` 到 `/var/www/bifrost-api-web/dist/`)
- **LOC**: ~590
- **Unlock AC**: AC-5, AC-6, AC-10 (live)

## 5. AC 验收状态 (8 PASS / 6 SKIP)

| AC | 描述 | 状态 | PR |
|---|---|---|---|
| AC-1 | nmap baseline 不变 | ✅ PASS via nftables drop contract (live diff via --execute) | PR-3 (rehearsal PR-7) |
| AC-2 | marketplace.json 在 git tree 内可读 | ⏸ DEFERRED on PR-3 | PR-3 |
| AC-3 | `git ls-remote` 成功 | ⏸ DEFERRED on PR-3 | PR-3 |
| AC-4 | `extraKnownMarketplaces` 设置已下发 | ✅ PASS via `jq settings.json.template` | PR-6 |
| AC-5 | `/plugin install` 落盘 | ⏸ DEFERRED on PR-3 + PR-5b | PR-7 |
| AC-6 | 版本回退 | ⏸ DEFERRED on PR-5b | PR-7 |
| AC-7 | server-b.sh idempotent | ✅ PASS via `test-in-docker.sh distribution` | PR-2 |
| AC-8 | bifrost-api `/marketplace/status` admin-gated | ✅ PASS via pytest 401/403/200 | PR-4 |
| AC-9 | SPA list API 可调 | ✅ PASS via pytest mock | PR-4 |
| AC-10 | Admin upload 触发 render | ✅ PASS mock via pytest; ⏸ live on PR-3 | PR-5a |
| AC-11 | LICENSE / NOTICE 输出 | ✅ PASS via `test -f LICENSE NOTICE` + grep ALL-RIGHTS-RESERVED | PR-2 |
| AC-12 | LICENSE fallback path | ✅ PASS via `check-upstream-schema.sh` 实运 + regex match | PR-7 |
| AC-13 | DNS + panel 域名 | ⏸ DEFERRED on PR-3 | PR-3 |
| AC-14 | docs 完整 | ✅ PASS via grep docs/USAGE.md + docs/SECURITY.md markers | PR-7 |

## 6. 测试基线

| 测试套件 | PASS | 增量 |
|---|---|---|
| `cd bifrost-api && python -m pytest tests/` | 66 PASS | PR-4 34 + PR-5a 32 |
| `tests/test-in-docker.sh distribution` | 51 PASS | 0519-1 26 + PR-2 19 + PR-5a 6 |
| `tests/test-in-docker.sh marketplace_skeleton` | 21 PASS | PR-1 render E2E |
| `tests/test-in-docker.sh syntax` | 61 PASS | 含 bifrost-admin-router.sh + build-marketplace-seed.sh + check-upstream-schema.sh |
| `bash scripts/e2e-distribution-rehearsal.sh` | exit 0 (7 pass / 0 fail / 6 skip) | PR-7 marketplace section |

## 7. 技术债登记 (TD-1..TD-5, cleanup PR 候选)

| # | 严重度 | 描述 | 建议解锁 PR |
|---|---|---|---|
| TD-1 | 中 | `marketplace.py` + `marketplace_admin.py` SSH wrapper 重复 (~80 LOC)。抽到 `bifrost-api/app/utils/ssh_runner.py` | cleanup PR before PR-5b |
| TD-2 | 低 | `bifrost-admin-router.sh` audit_log JSON 字符串拼接仅处理 `"`；backslash/newline 未转义。生产 message 全硬编码无注入面 | cleanup PR (jq 化) |
| TD-3 | 低 | `bifrost-admin-router.sh upload` verb 用默认 `tar -xzf`；`../` path traversal 未拒绝 | cleanup PR (`--no-relative-names` + `..` 拒绝) |
| TD-4 | 低 | `bifrost-readonly-router.sh` 未开放 `logs:admin-audit` verb；`/marketplace/logs?service=admin-audit` 返 422 占位 | PR-5a follow-up (1 行 case arm) |
| TD-5 | 低 | AC-7 docker 不可用时静态 grep fallback，不能验证量化 `<1s` 重跑指标 | 生产 `--execute` 时人工观察 |

## 8. 下次 follow-up 入口

### 入口 A: PR-3 解锁（高优先）

```bash
# 1. 检查 server-a-hardening-v2 status
cat .trellis/tasks/05-19-server-a-hardening-v2/task.json | jq -r .status

# 2. 若 status=completed 且 PR-3 已 merged-to-main:
#    启动本 task PR-3 子任务
#    spec.md §10.2 行 1120-1134 + spec.md §3.2 (panel.uuhfn.cloud Caddy 站点)
#    实施: configs/caddy/Caddyfile-a.tpl + scripts/server-a.sh + docs/USAGE.md DNS 段补充
```

### 入口 B: PR-5b SPA（依 PR-3 解锁）

```bash
# PR-3 落地后，启动 PR-5b:
#    spec.md §8 (Vue 3 SPA 架构) + spec.md §10.2 行 1175-1189
#    实施: bifrost-api-web/ + .github/workflows/ci.yml panel-build + scripts/server-a.sh --deploy-panel
#    LOC ~590, 不依赖 PR-7 (并行可)
```

### 入口 C: cleanup PR (技术债)

```bash
# 适合放在 PR-5b 之前作为重构 PR:
# - TD-1: abstract bifrost-api/app/utils/ssh_runner.py
# - TD-2: bifrost-admin-router.sh audit_log → jq
# - TD-3: bifrost-admin-router.sh tar hardening
# - TD-4: bifrost-readonly-router.sh logs:admin-audit verb (1 line)
```

## 9. 关键 spec 锚点 (file:line 实测)

- `bifrost-api/app/dependencies.py:40-54` — `require_admin` 读 `X-Admin-Key` header (C4 闭合，**严禁 Bearer**)
- `bifrost-api/app/config.py:38-49` — Settings: `server_b_wg_ip / readonly_* / admin_*` 三字段
- `bifrost-api/app/routers/mirrors.py:1-225` — 0519-1 镜像 router (PR-4/PR-5a 复刻 pattern)
- `bifrost-api/app/main.py:130-132` — `app.include_router` 序列 (含 mirrors + marketplace + marketplace_admin)
- `configs/caddy/Caddyfile-a.tpl:145-181` — `@*_private` vpn-first 模式（PR-3 复用）
- `configs/systemd/git-mirror@.timer` — `OnCalendar=*-*-* 02:00:00` (M1)
- `scripts/git-mirror-sync.sh:10-18` — matrix unchanged (**bifrost-internal-plugins 不进**, C6 闭合)
- `scripts/bifrost-readonly-router.sh:1-60` — readonly forced-command 白名单 (含 PR-2 marketplace case arms)
- `scripts/bifrost-admin-router.sh:1-233` — admin forced-command 白名单 (5 verbs: upload/tag-create/approve/curate/rerender)
- `prompts/0519-1/team-config/.claude/settings.json.template` — `extraKnownMarketplaces.bifrost-internal.source.{source:"url",url:"https://files.uuhfn.cloud/git/bifrost-internal-plugins.git"}` (C2/C3 闭合)
- `prompts/0519-1/marketplace-bootstrap/bifrost-internal-plugins/.claude-plugin/marketplace.json` — PR-1 seed (owner object + source-relative-path discriminator + 无 `git+` 前缀)

## 10. ADR 锁定状态

| ADR | 决策 | 状态 | 实证 |
|---|---|---|---|
| ADR-1 | monorepo source-relative-path | LOCKED | spec.md §6.1 |
| ADR-2 | Vue3 SPA + /plugin TUI dual panel | LOCKED | spec.md §8 + §10.2 PR-5b |
| ADR-3 | LAN-only read + X-Admin-Key write | LOCKED (corrected from Bearer in v1) | bifrost-api/app/dependencies.py:40-54 |
| ADR-4 | DENY upstream mirror, marketplace internal-only | LOCKED via WebFetch 实测 | spec.md §5.2 |

## 11. spec-review 闭合状态

31 findings closed:
- Critical: 6/6 (100%) — C1 marketplace.json 位置, C2 source discriminator, C3 git+ prefix, C4 X-Admin-Key, C5 AC-12 可测化, C6 self-mirror 死锁
- Major: 19/19 (100%)
- Minor: 6/6 (100%)

详见 `spec-review.md`（PR review 阶段对照标准）。

---

**Files in this directory**:
- `STATUS.md` (本文件)
- `prd.md` — PRD v1 (622 lines, 8 决策 + ADR-1..ADR-4)
- `spec.md` — spec v2 design-frozen (1447 lines, 16 sections)
- `spec-review.md` — 31 findings (6C + 19M + 6N)
- `task.json.snapshot` — Trellis task.json 快照 (含 pr_progress + ac_status + technical_debt + commit_chain)
