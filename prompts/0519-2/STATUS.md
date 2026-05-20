# Server B 内部 Claude artifacts marketplace + visual panel — STATUS

> **Snapshot taken**: 2026-05-20
> **Trellis task path**: `.trellis/tasks/05-19-server-b-claude-artifacts-marketplace-visual-panel/`
> **Branch**: `main`; local integrated implementation is in current `HEAD`
> **Phase**: `pr-3-pr-5b-td-cleanup-hardening-v2-local-implemented-browser-smoked-2026-05-20`

## 1. Quick summary

Bifrost server-b 内部 Claude artifacts marketplace + visual panel 的本轮 follow-up 已把 PR-3 本地代码合同、PR-5b Vue SPA/CI/deploy script、TD-1/TD-2/TD-3/TD-4 安全债落地到当前工作树；同时补齐上游依赖 `05-19-server-a-hardening-v2` 的 PR-1..PR-4 本地合同实现与 root/mirror parity。**PR-1b 仍永久 deferred**（ADR-4 LICENSE LOCKED）；生产级 DNS、真实 Server A/B 部署、inside-allowlist curl、真实 Claude client install/rollback 仍需 live cutover 证据，不能由本地测试伪完成。

本地浏览器 smoke 追加发现并修复了一个 PR-5b 路由合同问题：页面路由不再占用 `/marketplace/*`，该前缀保留给 bifrost-api JSON/TEXT API；SPA 页面改为 `/plugins`、`/status`、`/upload`、`/curate`，生产 Caddy 与 Vite dev proxy 均只把 `/marketplace/*` / `/api/*` 送到后端。`X-Admin-Key` 按 spec 回到 `sessionStorage`，API client 会拒绝 Vite/Caddy fallback HTML 这类非 JSON 响应，避免把 `index.html` 当成业务错误展示。

本地验证已覆盖：`syntax` 63 PASS、`distribution` 54 PASS、`marketplace_skeleton` 21 PASS、`hardening_v2` 14 PASS、`docs` 13 PASS、`bifrost-api/tests/` 68 PASS、`bifrost-api-web` lint/test/typecheck/build PASS。追加本地 browser smoke：Vite `127.0.0.1:4175` + 本地 FastAPI `127.0.0.1:8000`，桌面 `1440x900` 与移动 `390x844` 均可登录 `/status`，页面非空、导航可见、无横向溢出，admin key 仅存在 `sessionStorage`；因未接入真实 Server B readonly SSH，`/marketplace/disk` 返回 503 并在 UI 中显示“Server B 只读 SSH 通道未配置”，这是 live-deferred 环境缺口而非前端 mock。AC-13 等真实网络验收仍 deferred 到 `scripts/e2e-distribution-rehearsal.sh --execute`。

后续 live cutover 已固化为 `.trellis/tasks/05-19-server-b-claude-artifacts-marketplace-visual-panel/live-acceptance-runbook-2026-05-20.md`；当前用户选择“不执行 live”，所以该 runbook 仅作为授权后的执行/采证模板。2026-05-20 追加确认：用户在交互选项中选择“保持阻塞（推荐）”，继续禁止 production cutover、SSH、DNS/allowlist 检查、Caddy reload、Server A deploy/nmap/onboarding 和 `scripts/e2e-distribution-rehearsal.sh --execute`。

Hardening v2 DoD 的 `CHANGELOG` 要求已补：`CHANGELOG.md` 与 `ai-gateway-bridge/CHANGELOG.md` 均包含 Unreleased 条目，记录 Server A v0.6 hardening、marketplace panel follow-up 与 live-deferred 边界。

用户选择“一个整合提交”后，本地 follow-up 采用当前 `HEAD` 的 integrated commit 承载。这不是 PR-1..PR-4 四个独立 commit，而是用户确认的 commit 策略偏离；live 验收仍 deferred。本文不硬编码 self commit hash，避免 amend 后文档哈希漂移。

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

## 4. Deferred / follow-up PRs

### PR-1b: mirror anthropic/claude-code (**永久 deferred**)

- **Blocker**: ADR-4 LOCKED via WebFetch — anthropic/claude-code `LICENSE.md` = `© Anthropic PBC. All rights reserved.` + Anthropic Commercial ToS D.4/F 无 redistribution 授权
- **2026-05-20 live recheck**: GitHub `anthropics/claude-code/LICENSE.md` 仍为 Anthropic PBC all-rights-reserved（source: `https://github.com/anthropics/claude-code/blob/main/LICENSE.md`）；Claude Code legal docs 仍说明 Claude Code 使用受 Anthropic Commercial Terms / Consumer Terms 约束（source: `https://docs.anthropic.com/en/docs/claude-code/legal-and-compliance`），未发现 MIT/Apache-2.0/OSS 或 redistribution 授权变更
- **Unlock condition**: Anthropic 改 OSS license（MIT/Apache-2.0/etc.）
- **Monitor**: `scripts/check-upstream-schema.sh` 每日 cron 监测 sha256 drift；`UPSTREAM-CHANGED` 状态码触发 agent manager 介入
- **2026-05-20 watchdog temp-run**: 用临时 `BASELINE_SHA256_FILE` / `STATE_FILE` 执行 `scripts/check-upstream-schema.sh`，真实抓取上游 license 并输出 `LICENSE-BASELINE-INIT 728158fd1037143fad6907e8fa34804177e598b7326519503fe83cafdef849e6`；临时 `state.json` 写入 `upstream_alert=false` / `upstream_last_check_status=ok`，未写生产 `/etc` 或 `/var/lib`
- **Status snapshot**: `state.json.upstream_alert=false`, baseline sha256 已在 server-b deploy 时初始化

### PR-3: Server A `panel.uuhfn.cloud` Caddy + vpn-first allowlist + DNS 文档 (**LOCAL IMPLEMENTED; LIVE DEFERRED**)

- **External status**: 外部任务 `05-19-server-a-hardening-v2` 为 `in_progress_live_validation_deferred`，PR-1..PR-4 本地合同已经在当前工作树实现并验证；live Server A 部署/nmap/onboarding 证据未跑，所以不能声称 upstream task production-complete
  - `{{ADMIN_ALLOWED_RANGES}}` template var 来自 hardening-v2
  - `05-19-server-a-hardening-v2` 当前 status=`in_progress_live_validation_deferred`，meta 标记为 `local-implementation-complete-live-validation-deferred-2026-05-20`
- **本轮本地落地**:
  - `configs/caddy/Caddyfile-a.tpl` 和 `ai-gateway-bridge/configs/caddy/Caddyfile-a.tpl` 追加 `panel.{{DOMAIN}}` 站点（`@panel_private remote_ip {{ADMIN_ALLOWED_RANGES}}` + SPA static root + `/api/*` `/marketplace/*` 反代到 `127.0.0.1:8000`）
  - `scripts/server-a.sh` distribution inline Caddy 渲染同步 `panel.${distribution_domain}`
  - `docs/USAGE.md` 移除“PR-3 合并前默认 vhost”旧提示，补 `--deploy-panel` SOP
- **仍需 live 证据**: `dig +short panel.uuhfn.cloud`、inside allowlist `curl -I https://panel.uuhfn.cloud/` 200、outside allowlist 403

### Server A hardening v2 dependency: PR-1..PR-4 (**LOCAL IMPLEMENTED; LIVE SERVER A ACCEPTANCE DEFERRED**)

- **本轮本地落地**:
  - PR-1: Mihomo/Xray 本地代理面收紧、Reality SNI sync helper/hook warning、AI/dev whitelist 扩容
  - PR-2: `BIFROST_WG_PORT` 持久化、vpn-first firewall 语义、nftables strict template、fail2ban SSH-default 运行源
  - PR-3: `BIFROST_SERVER_A_TLS_MODE=internal`、vpn-first Caddy `bind 10.8.0.1`、legacy TLS mode deprecation banner
  - PR-4: 用户 onboarding bundle、CA 管理/轮换文档、WG `AllowedIPs` 去除硬编码 `172.16.0.0/24`
  - root 与 `ai-gateway-bridge/` 镜像同步；`docs/*` 中 WireGuard 端口说明改为读取 `/etc/bifrost.env` 的 `BIFROST_WG_PORT`，仅保留 legacy `51820` fallback 说明
- **本地验证**: `hardening_v2` 14 PASS、`syntax` 63 PASS、`mihomo` 6 PASS、`xray` 2 PASS、`security` 28 PASS、`vpn` 8 PASS、`user` 8 PASS、`deploy` 33 PASS、`docs` 13 PASS、`git diff --check` PASS
- **仍需 live 证据**: 真实 `./install.sh --server-a`、vpn-first + internal 的公网 nmap、legacy `domain/cloudflare-origin/ip` 生产部署回归、真实客户端 onboarding bundle

### PR-5b: Vue 3 SPA + CI workflow + deploy script (**LOCAL IMPLEMENTED; LIVE SPA E2E DEFERRED**)

- **本轮本地落地**:
  - 新增 `bifrost-api-web/` Vue 3 + Vite + Pinia + Vue Router SPA，使用真实同源 `/marketplace/*` 和 `/marketplace/admin/*` API，`X-Admin-Key` 存 `sessionStorage`，无 mock 数据
  - 页面路由与 API 路由拆分：SPA 使用 `/plugins`、`/status`、`/upload`、`/curate`；`/marketplace/*` 保留给 bifrost-api，避免 production Caddy 反代与 Vue history fallback 冲突
  - Vite dev proxy 将 `/marketplace/*` / `/api/*` 指向本地 FastAPI；API client 对非 JSON 响应 fail closed，防止 dev server fallback HTML 被当成 API payload
  - `.github/workflows/ci.yml` 新增 `panel-build` job，pnpm 在 setup-node 前执行，Node 20 + `cache: pnpm`
  - `scripts/server-a.sh --deploy-panel` 与 `install.sh --deploy-panel` 部署 `dist/` 到 `/var/www/bifrost-api-web/dist/`
- **本地验证**: `pnpm -C bifrost-api-web lint` / `test` / `typecheck` / `build` 全通过；Playwright desktop/mobile smoke 通过页面可见性、路由、sessionStorage、无横向溢出检查。真实 Server B readonly SSH 未配置时，后端 503 作为本地环境错误展示。
- **仍需 live 证据**: 真实 `https://panel.uuhfn.cloud` 浏览器登录、真实 upload/curate、Claude client install/rollback

## 5. AC 验收状态 (本地合同更新后)

| AC | 描述 | 状态 | PR |
|---|---|---|---|
| AC-1 | nmap baseline 不变 | ✅ PASS via nftables drop contract (live diff via --execute) | PR-3 (rehearsal PR-7) |
| AC-2 | marketplace.json 在 git tree 内可读 | ⏸ DEFERRED on production Server A/B deploy | PR-3 |
| AC-3 | `git ls-remote` 成功 | ⏸ DEFERRED on production Server A/B deploy | PR-3 |
| AC-4 | `extraKnownMarketplaces` 设置已下发 | ✅ PASS via `jq settings.json.template` | PR-6 |
| AC-5 | `/plugin install` 落盘 | ⏸ DEFERRED on live Server A/B + real Claude client | PR-7 |
| AC-6 | 版本回退 | ⏸ DEFERRED on live Server A/B + real Claude client | PR-7 |
| AC-7 | server-b.sh idempotent | ✅ PASS via `test-in-docker.sh distribution` | PR-2 |
| AC-8 | bifrost-api `/marketplace/status` admin-gated | ✅ PASS via pytest 401/403/200 | PR-4 |
| AC-9 | SPA list API 可调 | ✅ PASS via pytest mock | PR-4 |
| AC-10 | Admin upload 触发 render | ✅ PASS mock via pytest; ⏸ live upload/render still requires Server A/B cutover | PR-5a |
| AC-11 | LICENSE / NOTICE 输出 | ✅ PASS via `test -f LICENSE NOTICE` + grep ALL-RIGHTS-RESERVED | PR-2 |
| AC-12 | LICENSE fallback path | ✅ PASS via `check-upstream-schema.sh` 实运 + regex match | PR-7 |
| AC-13 | DNS + panel 域名 | ✅ LOCAL contract landed; ⏸ live DNS + allowlist curl deferred to `--execute` | PR-3 |
| AC-14 | docs 完整 | ✅ PASS via grep docs/USAGE.md + docs/SECURITY.md markers | PR-7 |

## 6. 测试基线

| 测试套件 | PASS | 增量 |
|---|---|---|
| `cd bifrost-api && python -m pytest tests/` | 68 PASS | PR-4 34 + PR-5a 32 + TD-1 ssh_runner 2 |
| `cd bifrost-api && python -m pytest tests/test_marketplace_router.py` | 34 PASS | PR-4 + TD-4 admin-audit log route |
| `pnpm -C bifrost-api-web lint && test && typecheck && build` | PASS (Vitest 4 tests) | PR-5b Vue SPA + API client/session regression |
| Playwright local browser smoke | PASS with live Server B deferred caveat | Desktop `1440x900` + mobile `390x844` on local Vite/FastAPI; `/status` route, sessionStorage, no horizontal overflow |
| `tests/test-in-docker.sh distribution` | 54 PASS | 0519-1 + PR-2 + PR-3 panel + PR-5a + TD-1/2/3/4 |
| `tests/test-in-docker.sh marketplace_skeleton` | 21 PASS | PR-1 render E2E |
| `tests/test-in-docker.sh syntax` | 63 PASS | 含 bifrost-admin-router.sh + build-marketplace-seed.sh + check-upstream-schema.sh + hardening helper scripts |
| `tests/test-in-docker.sh hardening_v2` | 14 PASS | Server A hardening v2 PR-1..PR-4 root + mirror contract suite |
| `tests/test-in-docker.sh docs` | 13 PASS | 文档完整性 + WireGuard port docs cleanup 后回归 |
| `bash scripts/e2e-distribution-rehearsal.sh` | exit 0 (7 pass / 0 fail / 6 skip) | PR-7 marketplace section |

## 7. 技术债登记 (TD-1..TD-5, cleanup PR 候选)

| # | 严重度 | 描述 | 建议解锁 PR |
|---|---|---|---|
| TD-1 | 中 | ✅ 本轮已修：`marketplace.py` + `marketplace_admin.py` 共用 `bifrost-api/app/utils/ssh_runner.py`，保留各自业务错误映射 | local follow-up |
| TD-2 | 低 | ✅ 本轮已修：`bifrost-admin-router.sh` audit_log 改为 `jq -cn` 生成 JSON object | local follow-up |
| TD-3 | 低 | ✅ 本轮已修：upload 解包前 `tar -tzf` 检查并拒绝绝对/父级路径，解包使用 `--no-same-owner --no-same-permissions` | local follow-up |
| TD-4 | 低 | ✅ 本轮已修：`bifrost-readonly-router.sh logs:admin-audit` + `marketplace.py` map + pytest 200 happy path | local follow-up |
| TD-5 | 低 | AC-7 docker 不可用时静态 grep fallback，不能验证量化 `<1s` 重跑指标 | 生产 `--execute` 时人工观察 |

## 8. 下次 follow-up 入口

### 入口 A: Live PR-3 验证（高优先）

```bash
# 0. 先按 runbook 准备授权、窗口、证据模板：
#    .trellis/tasks/05-19-server-b-claude-artifacts-marketplace-visual-panel/live-acceptance-runbook-2026-05-20.md
#
# 1. 检查 server-a-hardening-v2 status
cat .trellis/tasks/05-19-server-a-hardening-v2/task.json | jq -r .status

# 2. 若已明确进入计划 cutover（即使 task 仍因 live 证据缺口保持 in_progress）:
#    bash scripts/e2e-distribution-rehearsal.sh --execute
#    采集 dig panel.uuhfn.cloud、inside allowlist curl 200、outside allowlist curl 403
```

### 入口 B: Live PR-5b SPA E2E

```bash
# 本地 PR-5b 已实现。live E2E 需：
#    1. pnpm -C bifrost-api-web build
#    2. bash ./install.sh --deploy-panel
#    3. 浏览器在 VPN/管理网段访问 https://panel.uuhfn.cloud
#    4. 登录、list、upload、curate、rerender，并验证 Server B tag/state.json/admin-audit
```

### 入口 C: cleanup PR (剩余技术债)

```bash
# - TD-5: production --execute 时观察 AC-7 second-run <1s 量化指标
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

## 12. Completion audit judgment

**Objective audited**: 按 `prompts/0519-2/prd.md` 与 `prompts/0519-2/spec.md` 完成 Server B 内部 Claude artifacts marketplace + visual panel，并补齐依赖的 Server A hardening v2 本地合同，直到没有未覆盖任务。

**Local deliverables complete**:

- PR-3 local Server A `panel.uuhfn.cloud` Caddy / vpn-first / deploy-panel contract: implemented in root + `ai-gateway-bridge` mirror and covered by `distribution` / `hardening_v2` tests.
- PR-5b Vue SPA: implemented, route/API split verified, `sessionStorage` auth boundary covered, non-JSON API fallback regression covered, local desktop/mobile browser smoke passed.
- TD-1..TD-4: implemented and covered by pytest + `distribution` contracts.
- Server A hardening v2 PR-1..PR-4 local contracts: implemented, root/mirror parity verified, docs/CHANGELOG updated.
- PR-1b monitoring: latest public license/legal docs rechecked on 2026-05-20; temp-run of `scripts/check-upstream-schema.sh` verified watchdog behavior without writing production paths.

**Still not complete by design / authorization boundary**:

- PR-1b remains blocked until Anthropic grants an OSS/redistribution license.
- AC-2 / AC-3 / AC-5 / AC-6 / AC-10 live / AC-13 require production Server A/B, DNS, allowlist, real Claude client, and deployed panel evidence.
- Server A hardening v2 remains live-deferred until real deploy/nmap/onboarding evidence is collected.

**Final status**: local implementation is complete and locally verified. 2026-05-20 追加范围决定：用户将当前 Codex goal 的完成标准调整为“本地实现与本地验收完成，production live 继续 deferred”。因此当前 Codex goal 可按本地完成口径收口；但产品/部署层面的剩余 AC 与 PR-1b license blocker 仍未完成，Trellis task 的正确状态继续是 `in_progress_live_validation_deferred`，不得表述为 production-complete。

---

**Files in this directory**:
- `STATUS.md` (本文件)
- `prd.md` — PRD v1 (622 lines, 8 决策 + ADR-1..ADR-4)
- `spec.md` — spec v2 design-frozen (1447 lines, 16 sections)
- `spec-review.md` — 31 findings (6C + 19M + 6N)
- `task.json.snapshot` — Trellis task.json 快照 (含 pr_progress + ac_status + technical_debt + commit_chain)
