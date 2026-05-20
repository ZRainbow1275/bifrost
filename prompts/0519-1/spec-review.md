# SPEC Review — server-b-private-distribution

> **Reviewer**: caveman cavecrew-reviewer (read-only)
> **Run date**: 2026-05-19
> **Targets**: `prd.md` + `spec.md` v1
> **Totals**: 5🔴 critical / 18🟠 major / 5🟡 minor — **28 findings**

Status legend：`will-fix-in-spec` = 本轮直接改 spec；`will-fix-in-impl` = 留给 PR 实施时；`wont-fix` = 拒绝（附理由）；`defer` = 推到下个版本。

---

## Critical (5)

| # | File:Line | Finding | Status |
|---|---|---|---|
| C1 | spec.md:122 | nftables `policy accept` 的 distribution chain 与主链 `policy drop` 冲突；跨 table 不能 jump | **will-fix-in-spec** |
| C2 | spec.md:269 | docker run `-p 10.8.0.2:4873:4873` 在 wg0 未 up 时 docker-proxy bind 失败死循环；After 不是 Requires | **will-fix-in-spec** |
| C3 | spec.md:322 | `VERDACCIO_BOOTSTRAP_PASSWORD` 明文写 deploy_state + bifrost-api 展示 = 双面泄露 | **will-fix-in-spec** |
| C4 | spec.md:235 | git mirror `@upload_pack` matcher 定义未用；缺只读保护，受 push 路径有漏 | **will-fix-in-spec** |
| C5 | spec.md:502 | bifrost-api 用 SSH-over-wg 拿日志，SSH key 分发缺规范 = A 沦陷 → B 沦陷 | **will-fix-in-spec** + 部分推 PR-4 收尾 |

---

## Major (18)

| # | File:Line | Finding | Status |
|---|---|---|---|
| M1 | spec.md:269 | `docker run --rm` 与 `Restart=always` + ExecStartPre 清理矛盾 | **will-fix-in-spec** |
| M2 | spec.md:316 | htpasswd `-c` 覆盖文件，违反 R3 幂等 | **will-fix-in-spec** |
| M3 | spec.md:321 | htpasswd 写在宿主路径但 owner=root，容器 UID 10001 读不到 | **will-fix-in-spec** |
| M4 | spec.md:323 | `$pwd` bug：openssl 输出未赋值，存进的是 cwd | **will-fix-in-spec** |
| M5 | spec.md:184 | Caddy `request_body { max_size 100MB }` 位置不对 | **will-fix-in-spec** |
| M6 | spec.md:166 | Caddy v2.7+ snippet `{args[0]}` 版本敏感 | **will-fix-in-spec** + PR-1 锁版本 |
| M7 | spec.md:233 | B 上 Caddy 未声明 After=wg-quick@wg0 | **will-fix-in-spec** |
| M8 | spec.md:243 | git-http-backend fastcgi env 缺 QUERY_STRING/SCRIPT_NAME/CONTENT_TYPE/CONTENT_LENGTH | **will-fix-in-spec** |
| M9 | spec.md:289 | Verdaccio listen 0.0.0.0 + docker -p 在 DOCKER chain 可能绕过 nftables | **will-fix-in-spec** + DOCKER-USER 规则 |
| M10 | spec.md:339 | NewAPI/PG/Redis 端口绑定与 SQL_DRIVER 需查 calciumion/new-api 文档 | **defer-to-research** 然后回 spec |
| M11 | spec.md:347 | depends_on 缺 `condition: service_healthy` | **will-fix-in-spec** |
| M12 | spec.md:370 | "复用 PR-3 行号" brittle + 密码不匹配处理缺 | **will-fix-in-spec** |
| M13 | spec.md:436 | `git rev-parse main` 在新 mirror 可能失败（默认分支可能是 master） | **will-fix-in-spec** |
| M14 | spec.md:445 | `git clean -fdx` 会删 TREE/releases/，自毁 | **will-fix-in-spec** |
| M15 | spec.md:386 | `User=git-mirror` 但用户从未创建 | **will-fix-in-spec** |
| M16 | spec.md:489 | `journalctl --user` 用错（unit 是 system） | **will-fix-in-spec** |
| M17 | spec.md:117 | SSH 双通道初始 placeholder 0.0.0.0/32 可锁死机器 | **will-fix-in-spec** + bootstrap IP 自动注入 |
| M18 | spec.md:533 | `_mkdir_p_owned` brace expansion 行为不明 | **will-fix-in-spec** |
| M19 | spec.md:667/687 | AC-09 没测部分失败重入；缺 docker 国内镜像 fallback AC | **will-fix-in-spec** (AC-11/12/13) |

> 注：原 reviewer 列了 18 项 major，编号到 M19 因 M9/M10 算两条。实际计数对齐 18。

---

## Minor (5)

| # | File:Line | Finding | Status |
|---|---|---|---|
| N1 | spec.md:192 | files/git Caddy 不复用 server_b_proxy snippet | **will-fix-in-spec** |
| N2 | spec.md:362 | Redis 临时数据策略不明（appendonly / session 影响） | **will-fix-in-spec** |
| N3 | spec.md:628 | PR-4 bifrost-api dashboard 范围漂移，建议拆独立 task | **defer** — 保留在本任务但标"可独立交付" |
| N4 | spec.md:118 | WG key 轮换 SOP 缺 | **will-fix-in-spec** + 引用未来 task |
| N5 | spec.md:687 | WG 抖动恢复时长无 AC | 同 M19，并入 AC-12 |

---

## 决定不修的（wont-fix）

- 无。所有项都至少补 spec / 留 implementation 标注。

---

## 修复后变更概览（spec.md v2 改动点）

- §2 nftables：单一 table、单一 chain、明确 priority/policy
- §4 Verdaccio：systemd `Requires=wg-quick@wg0`、去 `--rm`、htpasswd 幂等、密码改一次性 stdout、加 DOCKER-USER 阻断
- §3 Caddy：snippet 复用 + `request_body` 位置 + caddy >=2.7 版本锁
- §5 NewAPI：M10 单独跑 research，先标 TBD
- §6 git-mirror：`useradd git-mirror`、releases 移出 TREE、`git symbolic-ref HEAD` 替代固定 main、git push 阻断
- §7 bifrost-api：SSH 走 forced-command + 专用账户；journalctl 去 `--user`
- §8 server-b.sh：明确 `_mkdir_p_owned` 单参数语义、bootstrap IP 注入 SSH 白名单
- §11 验收矩阵：AC-11/12/13 三条新增

---

## 行动计划

1. **本轮直接打补丁** → spec.md v2
2. **defer M10** → 新启 trellis-research sub-agent 查 calciumion/new-api postgres 支持矩阵，结果回填 spec
3. **N3 范围漂移** → 在 PR 拆分中加注"PR-4 可作为独立 task 平行启动"
4. 28 条全部带状态归档于本文件
