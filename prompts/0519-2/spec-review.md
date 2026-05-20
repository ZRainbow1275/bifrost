# spec.md v1 Review Findings

> Bound spec: `spec.md` (1156 lines)
> Bound PRD: `prd.md` (622 lines)
> Reviewed against: repo HEAD on branch main, 2026-05-19
> Format reference: `prompts/0519-1/spec-review.md`

## Summary

- Critical: 6
- Major: 19
- Minor: 6
- Total: 31

## Critical

C1. spec.md:48,102,348,993: Critical: marketplace.json protocol location wrong. Anthropic protocol (docs.claude.com plugin-marketplaces.md Host on GitHub) mandates the marketplace file at `.claude-plugin/marketplace.json` inside the repo. Spec lands the render output at `/var/lib/dist/plugins/marketplace.json` as a sidecar static file. `/plugin marketplace add https://files.uuhfn.cloud/git/bifrost-internal-plugins.git` is a git-mode add: the client clones the bare repo and reads `<workdir>/.claude-plugin/marketplace.json`, never consuming the dist sidecar. AC-2 verifies a URL the client never uses. Fix: render-marketplace-json.sh must clone bare into a temp worktree, write `.claude-plugin/marketplace.json`, commit, push back to bare; or switch to URL-based marketplace and drop git-subdir (loses relative paths and ref semantics). Either choice rewrites Sections 4.2 / 4.3 / 6 / 9.1.

C2. spec.md:279,297,300,308: Critical: marketplace.json schema fields illegal.
  - L279 owner: "bifrost-team" must be object: {"name": "..", "email": ".."} (plugin-marketplaces.md Required fields: owner=object with sub-fields name+email). String value rejected by schema; /plugin marketplace add fails.
  - L297 "source": {"type": "git-subdir", ...} should be "source": {"source": "git-subdir", ...}; the protocol discriminator key is source, not type.
  - L298 "url": "git+https://..." -- git+ prefix is not in schema (docs: url Required. Full git repository URL https:// or git@).
  - L308 tarball_url / tarball_sha256 are custom fields; git-subdir does not consume tarballs -- protocol install uses sparse clone. Rendered <name>/releases/<ver>.tar.gz is never consumed. Rewrite Section 4.1 schema against protocol.

C3. spec.md:518,536,535,1118: Critical: /plugin marketplace add URL prefix git+https:// invalid. Anthropic CLI (/en/discover-plugins) accepts bare https://...git, owner/repo, or ./local-path; no git+ form. Spec uses git+https://...git in Section 0.1 L67, Section 6.3 L523, Section 11 AC-3, Section 16 commands. Team members executing spec hit client reject. Fix: drop git+ prefix everywhere; use https://files.uuhfn.cloud/git/bifrost-internal-plugins.git.

C4. spec.md:725,1115,1125: Critical: auth header mismatched with production -- security risk plus panel deployable to zero usability. bifrost-api/app/dependencies.py:40-54 require_admin strictly reads X-Admin-Key header. Spec Section 8.6 SPA flow (header.Authorization = Bearer ${token}), Section 16 curl examples (-H Authorization: Bearer $BIFROST_ADMIN_KEY), AC-8 verification all use Authorization: Bearer. Result: (a) every Vue SPA request 401; (b) AC-8 auto-test fails; (c) /marketplace/admin/upload unreachable. Fix: in Section 7 either extend require_admin to also accept Authorization: Bearer (backward-compat), or rewrite spec back to X-Admin-Key. Align AC-8, AC-9, AC-10, Section 16.

C5. spec.md:1003 (AC-12): Critical: AC-12 LICENSE fallback path not measurable. AC-12 reads: upstream-schema-check.service detects anthropic LICENSE unchanged, exits 0 + journals "no change" -- no shell command CI can run. Every other AC ships nmap / curl / jq. This is the only verification gate for the entire ADR-4 fallback. Fix: ship a concrete command, e.g. bash scripts/check-upstream-schema.sh && journalctl -u upstream-schema-check.service -n 20 | grep -E "^(LICENSE-OK|UPSTREAM-CHANGED)" | head -1 must print LICENSE-OK <sha256>, and jq .upstream_alert /var/lib/dist/plugins/state.json returns false.

C6. spec.md:786-802 + scripts/git-mirror-sync.sh:10-18: Critical: bifrost-internal-plugins self-referencing upstream deadlocks git clone --mirror. git-mirror-sync.sh:26-28 executes git clone --mirror ${upstream} ${bare} when bare missing. When upstream=file:///var/lib/git-mirrors/bifrost-internal-plugins.git and bare is same path, git refuses to clone into non-empty existing dir; if timer fires before bare exists, empty file:// source clones into empty bare. L34 git rev-parse default_branch, L51 git reset --hard origin/default_branch cannot work without origin or content. L52 git clean -fdx on /var/lib/dist-tree/bifrost-internal-plugins/ wipes admin-pushed tree (conflicts with marketplace-render output paths; RK-12 claim of natural separation is wrong). Fix: either remove bifrost-internal-plugins from the git-mirror-sync matrix entirely, or early-return in case arm when self-referencing.

## Major

M1. spec.md:802: Major: collides with existing git-mirror@.timer (configs/systemd/git-mirror@.timer:5 OnCalendar=*-*-* 02:00:00, daily). Spec narrative "update-server-info every 30 minutes" is factually wrong; PRD architecture L305 also claims default 30-minute cadence. A 30-minute cadence needs a new timer instance or drop-in override, not mentioned. Fix: either accept daily cadence, or add git-mirror@bifrost-internal-plugins.timer.d/override.conf with explicit OnCalendar=*:0/30.

M2. spec.md:215-228: Major: Caddy panel.uuhfn.cloud handle_path /assets/* + handle /marketplace/* + handle /api/* + default handle { try_files; file_server; } -- in Caddy v2 handle_path and handle are mutually-exclusive route groups, but spec also re-declares root inside default handle. Real issue: handle /api/* { reverse_proxy 127.0.0.1:8000 } sets no header_up Host {host} / X-Forwarded-Proto; bifrost-api will not see panel.uuhfn.cloud as Host, breaking future origin/CORS checks. Fix: emulate Caddyfile-a.tpl:259-263 (server_b_proxy) snippet -- add header_up.

M3. spec.md:202-228: Major: panel.uuhfn.cloud missing the Server A hardening-v2 style vpn-first allowlist. api.uuhfn.cloud NewAPI admin UI is guarded by @newapi_private { remote_ip {{ADMIN_ALLOWED_RANGES}} } (Caddyfile-a.tpl:151-181), but panel exposes the whole admin surface with zero remote_ip allowlist -- admin-token brute-force surface on public internet. RK-4 mentions optional ADMIN_ALLOWED_RANGES but treats it as PR-3 optional hardening, not MVP blocker. ADR-3 LAN-only public read + admin Bearer write makes writes admin-gated, but exposing write endpoints publicly means leaked tokens become production breach. Fix: panel.uuhfn.cloud must enforce vpn-first allowlist (same as /manage/*); optional becomes required.

M4. spec.md:166,169: Major: Section 3.1 import server_b_proxy http://10.8.0.2:8081 -- (server_b_proxy) snippet at Caddyfile-a.tpl:249-256 accepts one positional arg {args[0]}, usage OK. Snippet lacks health_uri / health_interval (review dimension 2), same already-noted 0519-1 weakness. Spec Section 3.1 does not fix this. Fix: the new /plugins/* proxy path should at least set transport http { dial_timeout 5s } to prevent static marketplace asset stalls from blocking the panel.

M5. spec.md:355-362: Major: marketplace-render.path watches /var/lib/git-mirrors/bifrost-internal-plugins.git/refs/tags (dir). Bare repo receiving initial push lands tag at refs/tags/<name>, but git gc / git pack-refs migrates them into packed-refs. PathChanged=refs/tags on dir uses inotify create/delete events; writing to packed-refs does not trigger refs/tags dir events. Re-pushing same tag after gc may not refire render. Path unit also missing [Path] MakeDirectory= and [Unit] Requires= / After= chain. Fix: use PathModified= instead of PathChanged= (PathChanged is create/delete, not modify); After=git-mirror@bifrost-internal-plugins.service so path unit starts after bare exists.

M6. spec.md:365-379: Major: marketplace-render.service logs to /var/log/marketplace/render.log, but _distribution_prepare_marketplace_dirs (Section 9.1 L760) only mkdir /var/log/marketplace -- no owner declared. User=git-mirror cannot write root-owned dir. Same for upstream-schema-check.service writing /var/log/marketplace/schema-check.log. Fix: helper must install -d -m 0750 -o git-mirror -g git-mirror /var/log/marketplace.

M7. spec.md:470-477: Major: upstream-schema-check.service curls github.com but has no Requires=network-online.target / After=network-online.target. On slow-boot machines timer fires before DNS ready -- curl errors and upstream_alert false-positive. Fix: add [Unit] Requires=network-online.target and After=network-online.target.

M8. spec.md:724,729: Major: Section 8.6 describes SPA calling POST /api/auth/verify { token } but Section 7 contract (L574-582) does not declare this endpoint, and bifrost-api has no /auth/verify route (full-repo grep confirms zero hits). Login.vue will 404. Fix: either add POST /auth/verify to Section 7 (request {token}, validation = string-compare against admin_key), or in Section 8.6 use the first protected request 200/401 to decide token validity and remove the verify endpoint.

M9. spec.md:729: Major: Section 8.6 trailing "CORS only allows panel.uuhfn.cloud origin (configured in config.py:44 cors_allow_origins)" contradicts Section 3.2 -- Caddy reverse-proxies panel.uuhfn.cloud/api/* to 127.0.0.1:8000, browser origin = https://panel.uuhfn.cloud, same-origin, no CORS preflight. The CORS config is no-op and misleads future maintainers. Fix: delete the CORS line, or qualify as "only enable CORS when panel/api are served from different Caddy sites".

M10. spec.md:705,701: Major: CI workflow panel-build step order wrong. actions/setup-node@v4 with cache: pnpm needs pnpm available during cache restoration, but spec order is setup-node, then corepack enable, then pnpm install. setup-node cache step runs before corepack enable -- pnpm binary missing -- cache step errors or silently skips. Standard pattern: pnpm/action-setup@v3 before actions/setup-node@v4. Fix: insert - uses: pnpm/action-setup@v3 with { version: 8 } before setup-node.

M11. spec.md:932-947 (PR-5 LOC): Major: PR-5 LOC estimate clearly over budget. Items: marketplace_admin.py ~300 + bifrost-admin-router.sh ~80 + _distribution_configure_admin_ssh ~50 + bifrost-api-web/ ~500-700 + .github/workflows/ci.yml ~30 + scripts/server-a.sh --deploy-panel ~60 + test_marketplace_admin_router.py ~150 = ~1170-1370 LOC, well over 800. Spec admits "closest to 800" but numbers cannot total 800. Fix: split PR-5a (backend admin write router + admin SSH channel + tests, ~580 LOC) plus PR-5b (Vue SPA + CI workflow + deploy script, ~590 LOC).

M12. spec.md:807-815: Major: Section 9.4 disable_distribution increment conflicts with production -- spec adds systemctl disable --now git-mirror@claude-for-legal-zh.timer, but scripts/server-b.sh:2698 already has it; spec also adds marketplace-render.path / upstream-schema-check.timer disable OK. But stop git-mirror@claude-for-legal-zh.service (scripts/server-b.sh:2699) is omitted. Fix: state that Section 9.4 appends three lines to existing disable block, do not duplicate.

M13. spec.md:822: Major: PR dependency diagram contradicts the per-PR Dependencies fields. Diagram shows PR-5 --> PR-6 --> PR-7, but Section 10.6 (PR-6) Dependencies: PR-1..PR-4 excludes PR-5; Section 10.7 (PR-7) Dependencies: PR-1..PR-6 includes PR-5. PR-6 can ship in parallel with PR-5. Fix: diagram fork-join with PR-5 and PR-6 in parallel before PR-7, consistent with Section 10.6 dep field.

M14. spec.md:1022 (RK-10): Major: cross-task coordination -- spec depends on 05-19-server-a-hardening-v2#PR-3 but never declares this task PR-3 (Caddyfile-a.tpl edit) must wait for hardening-v2 PR-3 merge. RK-10 describes wait or rebase as mitigation, not gate. Fix: Section 10 PR-3 Dependencies must explicitly list external: 05-19-server-a-hardening-v2#PR-3 merged-to-main.

M15. spec.md:992,995,1000-1001: Major: AC-1 / AC-4 / AC-9 / AC-10 lack runnable verification commands.
  - AC-1 has nmap -p- <B_PUB_IP> > nmap-after.txt && diff nmap-before.txt nmap-after.txt but does not say where nmap-before.txt is produced.
  - AC-4 clean Claude Code client: /plugin marketplace add ... appears in Marketplaces tab -- Marketplace tab is interactive TUI, not scriptable. Fix: invoke claude --headless or spawn claude + expect Marketplaces, hardcoded in E2E rehearsal script.
  - AC-9 manual browser login, no scripted assertion. Fix: playwright or curl-simulate the SPA call chain -- curl https://panel.uuhfn.cloud/marketplace/list -H ... returns plugin array.
  - AC-10 POST upload, tag creation, git_head_sha update -- no curl example. Fix: append curl -F tarball=@... -F manifest=@... ... && git -C /var/lib/git-mirrors/bifrost-internal-plugins.git tag --contains <sha> | grep plugins/hello-world-skill/v0.2.0.

M16. spec.md:586: Major: when extending bifrost-readonly-router.sh, spec lists 6 new case arms including logs:git-mirror-bifrost-internal-plugins which bakes the slug into the arm name. bifrost-readonly-router.sh:14-23 logs:git-mirror arm uses repo as second positional arg with inner allowlist. Fix: extend the inner allowlist inside logs:git-mirror to include bifrost-internal-plugins, rather than creating a new arm. Otherwise every new slug adds new arm.

M17. spec.md:535,531: Major: Section 6.3 upload/approval flow self-contradicts. L532 "3. PR flow (GitHub / GitLab / push to some origin alias on B)" -- no team GitHub repo (ADR-4 denies external mirror), and push to origin alias on B breaks read-only edge (Caddyfile-b-distribution.tpl:22-28 hardcodes 403 receive-pack). Where dev PR review happens is undefined. Fix: state explicitly where PR review occurs (admin via panel upload? dev push to own fork?) -- without this step, onboarding has no runnable flow.

M18. spec.md:340: Major: Section 4.2 render script writes marketplace.json to .tmp then atomic mv -- after C1 is resolved, does this atomic write happen inside git worktree or dist dir? If inside git tree, git add + commit + push required, not mv. Render script interface contract (exit codes, idempotency claim L344) must be rewritten. Fix: merge with C1 resolution; clarify write location.

M19. spec.md:733,743-745: Major: Section 9.1 step insertion location -- spec says step 07_render_marketplace NEW (insert after 06, before 08). Reality: enable_distribution already skips step 07 (scripts/server-b.sh:2630 has 06, next is 2640 with 08 -- there is a gap). Placement OK. But spec does not say which step enables marketplace-render.path -- step 05_render_systemd only cp templates, no systemctl enable --now marketplace-render.path. Fix: Section 9.1 step 07 must include systemctl enable --now marketplace-render.path and systemctl enable --now upstream-schema-check.timer.

## Minor

N1. spec.md:752: Minor: Section 9.1 step 13_restic "add /var/lib/dist/plugins/ to restic backup" -- redundant. scripts/bifrost-restic-backup.sh:23 already backs up /var/lib/dist (includes sub-dirs).

N2. spec.md:128: Minor: Section 1.1 row panel.uuhfn.cloud labels process caddy, coexists with Section 3.2 panel site handle /marketplace/* reverse_proxy to bifrost-api -- not contradictory but cluttered. Simplify to: Caddy reverse-proxies /api+/marketplace to bifrost-api, other paths serve SPA static.

N3. spec.md:687: Minor: dependency pin pinia@2; mid-2026 Pinia 3 is stable. No technical impact but inconsistent with Vue 3.5 + Vite 5 mainline. Fix: pinia@3.

N4. spec.md:507-509: Minor: Section 6.1 monorepo structure diagram is missing .claude-plugin/marketplace.json root node (resolve alongside C1).

N5. spec.md:149,202: Minor: Section 1.3 panel.uuhfn.cloud auth matrix Admin Bearer token coexisting with Section 3.2 Caddy block having no remote_ip allowlist = publicly reachable. Same root as M3; matrix description is factually correct (Caddy without allowlist is indeed LAN-public + token-gated). Issue lives in Section 3.2 design choice.

N6. spec.md:683: Minor: package.json snippet missing "type": "module", "private": true, devDependencies split -- spec is illustrative, but Vite + vue-tsc project without type: module makes vite.config.ts resolved as CommonJS while Vite 5 defaults to ESM. Fix: include "type": "module".

## Cross-Cutting Observations

- C1+C2+C3 share one root cause: spec did not actually read the Anthropic plugin-marketplaces protocol reference (docs.claude.com /en/docs/claude-code/plugin-marketplaces.md). Before v2, re-read that document and rewrite Section 4 + Section 6 repo structure (must include .claude-plugin/marketplace.json) + Section 0.2 data flow + AC-2 / AC-3 / AC-5 (redo verification commands).
- C4+M8+M9 are the auth-flow root cluster: admin auth header diverges from production, new /auth/verify not in route contract, CORS config no-op. Rewrite the auth matrix and frontend login state machine in v2 Section 7 + Section 8.6.
- C6+M1+M16+M19 are the git-mirror systemd integration root cluster: self-referencing upstream, timer cadence wrong, router arm naming inconsistent, step 07 enable missing. Draw a dedicated marketplace and git-mirror systemd relations diagram in v2 Section 9.
- Overall: spec v1 file:line anchors are accurate (all citations match HEAD), but protocol conformity and production-code conformity are weak. v2 must rewrite Sections 4 / 7 / 8 / 9 against actually runnable + legal evidence already validated.

## Verification Checklist (for spec v2)

- [ ] All Critical resolved (C1 marketplace.json placement, C2 schema field names, C3 add URL prefix, C4 auth header, C5 AC-12 command, C6 self-referencing upstream)
- [ ] >80% Major resolved or explicitly deferred with rationale
- [ ] AC-12 LICENSE fallback path has concrete shell command (C5)
- [ ] AC-4 / AC-9 / AC-10 ship scriptable verification commands (M15)
- [ ] Section 4 marketplace.json schema 1:1 calibrated against docs.claude.com plugin-marketplaces.md (C1+C2)
- [ ] Section 6.1 repo structure adds .claude-plugin/marketplace.json root entry (N4 with C1)
- [ ] Section 7 and Section 8.6 auth flow unified (C4+M8+M9)
- [ ] Section 9 marketplace-render pipeline (path unit / service / step 07 / git-mirror-sync self-reference handling) consistent (C6+M5+M6+M7+M19)
- [ ] PR-5 split to 5a + 5b and update Section 10 LOC (M11)
- [ ] AC-1 baseline file production step written into docs or rehearsal script (M15)
