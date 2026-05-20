# PRD — Bifrost Server B 承担私有分发 VPS 角色

> **Task**: `.trellis/tasks/05-19-server-b-private-distribution`
> **Owner**: ZRainbow
> **Status**: planning (brainstorm in progress)
> **Created**: 2026-05-19

---

## Goal

把上一轮在 **Windows VPS（uuhfn.cloud）** 上落地的"团队工具私有分发栈"（Verdaccio + 静态文件 + git mirror + claude-for-legal-ZH）整体下沉到 **Bifrost 项目的 Server B**，让 B 在保留现有 Xray/3x-ui 角色的同时承担**私有分发源**职责，并通过 **A 反代 + WireGuard + nftables 严格白名单** 实现：

1. **Server B 0 公网端口暴露给互联网**（4873/git/files 全部走 wg0 接口）。
2. **Server A 保持纯网关属性**（只做 TLS 终止 + reverse_proxy，不存储 mirror 数据）。
3. **仅 Server A + 少数白名单 VPS（如 Cloudflare Tunnel 节点、第二台 Hub）** 能通过 WireGuard 联通 B 的私有服务。
4. **团队成员**仍然只看见 `https://npm.uuhfn.cloud / files.uuhfn.cloud`（指向 A），完全感知不到 B 的存在。

---

## What I Already Know

### 项目侧现状（caveman-investigator 输出）

- `scripts/server-a.sh`（3328 行）：A 一键部署器，已含 NewAPI + Caddy + WireGuard + 三种 TLS 模式（domain / cloudflare-origin / ip）。
- `scripts/server-b.sh`（2611 行）：B 一键部署器，**当前只装 Xray VLESS+Reality + 3x-ui + nftables 出站白名单 + BBR**，**没有 docker，没有 mirror 服务**。
- `scripts/vpn.sh`：WG 网段 `10.8.0.0/24`，gateway `10.8.0.1`，端口 51820 (readonly)。
- `configs/caddy/Caddyfile-a.tpl`（258 行）：已含 placeholder `{{TLS_CERT_FILE}}` / `{{CLOUDFLARE_ORIGIN_CERT_FILE}}` / `{{DOMAIN}}`。
- `configs/caddy/Caddyfile-b.tpl`：B 上 Caddy 当前**仅作 3x-ui 面板 + decoy** 用，是 vpn-first 的 parity fixture。
- `bifrost-api/`：FastAPI 管理面，跑在 A 上，`reverse_proxy 127.0.0.1:8000`。

### 已存在但**未完成**的相邻任务

- `.trellis/tasks/05-19-server-a-hardening-v2/`（in_progress）：PR-3 会加入 **`internal` TLS 模式（Caddy local CA）** 和 **Caddy `bind 10.8.0.1` vpn-first 监听** —— 本任务**强依赖** PR-3 完成。
- `.trellis/tasks/05-18-newapi-uuhfn-cloud-package/`（in_progress）：当前 NewAPI 部署在外部 Windows VPS（不在 Bifrost A 上），本任务**不打算迁移 NewAPI**。

### 上一轮 Windows VPS 资产（已存在于 `prompts/0519-1/`）

- `VPS-团队工具分发-教程.md`（23KB）：Windows + pm2 + Verdaccio + Caddy 全套教程。
- `团队-DeepSeek-V4-cc-switch-配置教程.md`（10KB）。
- `claude-for-legal-mirror/`（6 文件，26KB）：tarball + 裸 git 双轨镜像。
- `团队-配置填写指南.md` + `team-config/`：脱敏后的 .claude.json/settings.json 模板。

这些资产**保留 Windows VPS 作为冷备**的同时，需要把"主力镜像源"迁到 Bifrost 双机架构。

### 调研结论（已持久化到 `research/`）

| 话题 | 结论 |
|---|---|
| `01-vpn-reverse-proxy.md` | A 作 hub，Caddy L7 `reverse_proxy 10.8.0.2:4873`，私钥放 A；不上 caddy-l4（experimental）。 |
| `02-linux-git-mirror.md` | MVP：systemd timer + nginx/Caddy smart HTTP（git-http-backend CGI）。中期备选：Gitea 容器（v1.26.1，端口 3000）。 |
| `03-verdaccio-linux.md` | Verdaccio v6.7.1 容器化，**必须设 `VERDACCIO_PUBLIC_URL`**（v5+ 优先级最高，覆盖 X-Forwarded-Proto）；restic 0.18.1 每日推 A 备份。 |

---

## Assumptions（待用户确认）

1. **Server B 已有公网 IP**（用于初始接入 WG），后续可关闭对公网的所有非-wg 入站。
2. **Server A 是入口域名 `uuhfn.cloud` 的 A 记录目标**。
3. **白名单"几个 VPS"** 是已经存在的、由用户管理的 WG peer，本任务不负责创建它们。
4. **Cloudflare 当前是灰云直连**（DNS-only），未启用橙云代理。如启用橙云，Origin CA 私钥仍放 A。
5. **NewAPI 不在迁移范围内**，本轮仅迁移"团队工具分发栈"（Verdaccio / 静态 files / git mirror）。

---

## Strategic Expansion（DIVERGE — 三个方向供选择）

### 1. 未来演进可能

- **B 作多租户镜像 hub**：除了 npm/git，还可加 PyPI（devpi）、Docker registry mirror、HuggingFace 模型镜像，承担"律所 / 团队级 OSS 私有源"。
- **NewAPI DB 备份目的地**：B 可作为 A 上 PG 的远程备份接收端（restic / pgbackrest），强化 A 容灾。
- **AI provider 出站代理**：B 通过 WG 把出站流量打回 A 的 Xray，避免 A 直接暴露在第三方 API 视野中（与现有 anti-DPI 链路协同）。

### 2. 相关并行场景

- **bifrost-api 管理面**：目前在 A 上，是否在管理面里加 "镜像源运维 dashboard"（手动触发 sync、查看 Verdaccio 日志）？
- **claude-for-legal-ZH 镜像迁移**：原本在 Windows VPS 的镜像本任务一并搬到 B，**唯一来源在 B**，Windows VPS 转为冷备。
- **DeepSeek V4 配置文件 / settings.json.template 分发**：目前在 Windows VPS 的 `files.uuhfn.cloud/team-config/` 也要走 B。

### 3. 失败 / 边界场景

- **WG 链路中断**：A 反代到 B 失败 → 客户端 npm install 全挂。需要 A 端 fallback（serve stale snapshot 或 502 友好页）+ healthcheck 探活。
- **B 公网 IP 漂移**（云厂商重建）：A 的 WG peer endpoint 需自动更新；server-b.sh 部署完应回写 SERVER_B_IP 到 A。
- **Verdaccio storage 损坏 / 误删**：恢复 SOP 走 restic A→B 反向。
- **Cloudflare Origin CA 与 internal CA 私钥并存于 A**：路径必须严格分离，文件权限 0400 root:root。

---

## Open Questions（全部已闭合）

| # | 议题 | 答案 | 决策 |
|---|---|---|---|
| Q1 | MVP 范围 | C — B 全能化 + NewAPI 迁移 | D1 |
| Q2 | NewAPI 数据迁移 | 绿启（不迁移） | D2 |
| Q3 | A↔B TLS 拓扑 | α — A L7 终止 + wg 明文 | D3 |
| Q4 | Windows VPS 处置 | 迁移后下线 | D4 |
| Q5 | 运维入口 | CLI 主 + bifrost-api 只读 dashboard | D5 |

---

## Requirements（evolving — 当前已锁定项）

- **R1**: Server B 必须 **0 公网入站端口**（除 wg0/51820 与 SSH 双通道）。
- **R2**: 团队成员域名访问体验**与上一轮 Windows VPS 完全等价**（`https://npm.uuhfn.cloud/` 等可用）。
- **R3**: 部署必须可重入（idempotent），跑两次 `server-b.sh --enable-distribution` 不出错。
- **R4**: 与 05-19-server-a-hardening-v2 PR-3 的 `internal` TLS / vpn-first bind 兼容。
- **R5**: 所有镜像数据可由 restic 每日推送到 Server A 上的备份卷。

---

## Acceptance Criteria（evolving）

- [ ] `nmap -p- <SERVER_B_PUBLIC_IP>` 仅显示 `22/tcp open` + `51820/udp open`，其它端口 closed/filtered。
- [ ] `curl -I https://npm.uuhfn.cloud/` 在团队成员机器上返回 200，Verdaccio version header 一致。
- [ ] `git ls-remote https://files.uuhfn.cloud/git/claude-for-legal-ZH.git` 成功。
- [ ] 手动 `wg-quick down wg0` 关闭 A 的 WG → npm install 失败 + Caddy 日志显示明确 502 + healthcheck 告警。
- [ ] `restic snapshots` 在 A 上能看到 B 的每日增量。
- [ ] `bash scripts/server-b.sh --enable-distribution` 跑两次都成功，第二次秒级完成。

---

## Definition of Done

- 上述 Acceptance Criteria 全部勾选
- 新增 / 修改的 shell 脚本通过 `tests/test-in-docker.sh` parity check
- `docs/USAGE.md` 增加新章节，`docs/SECURITY.md` 同步白名单矩阵
- `prompts/0519-1/spec.md` 落地
- `.trellis/tasks/05-19-server-b-private-distribution/` 内的 implement.jsonl/check.jsonl 完整

---

## Out of Scope（explicit）

- ~~NewAPI 迁移到 B~~ **（D1 决策后已纳入范围）**
- 新增 Tailscale / AmneziaWG / Firezone UI（保持 WG 原生）
- **bifrost-api 管理面迁移到 B**（暂留 A，跨 wg0 调用 B 的 NewAPI admin API）
- Xray VLESS+Reality / 3x-ui 角色变更（B 上现有功能保持不变）
- Anti-DPI / split-tunnel / keepalive 链路逻辑（不动）
- 删除上一轮 Windows VPS 上的 mirror 实例（处置策略走 Q4）
- 团队成员客户端配置变化（域名不变 → 客户端 0 改动）
- NewAPI 业务功能变更（仅做物理迁移，不改 schema/插件）

---

## Decision (ADR-lite)

### D1 — MVP 范围 = C（B 全能化 + NewAPI 迁移）  [2026-05-19]

**Context**：用户希望一次性把 A 的角色压缩到"纯 TLS 终止 + reverse_proxy 网关"，把所有有状态服务（NewAPI、PG、Verdaccio、git mirror、静态 files）全部下沉到 B；A 上的 NewAPI 同步迁移过去。

**Decision**：采用 C 路线 —— 在基础三件套（Verdaccio + files + git mirror）之上，**把 NewAPI + PostgreSQL 数据库一并迁到 B**。A 仅保留：Caddy（TLS 终止 + reverse_proxy）、WireGuard hub、SSH、bifrost-api FastAPI 管理面（管理面**暂留 A**，作为指挥控制平面）。

**Consequences**：

- 与 `.trellis/tasks/05-18-newapi-uuhfn-cloud-package/` 强耦合：那里的"外部 Windows VPS 上的 NewAPI"将被 B 上的 NewAPI 替代为团队主用实例。
- 与 `.trellis/tasks/05-19-server-a-hardening-v2/` 深度交叉：A 不再 install NewAPI（PR-1/PR-2 的 NewAPI 加固代码部分变成"代理路径加固"而非"本地服务加固"）。需协调两任务的合并顺序。
- 范围 8+ PR，预计 8 周+。
- A 上 NewAPI 数据需要"无损迁移"到 B，引入新的 cutover 风险。
- B 上引入 docker（Verdaccio + NewAPI + PG + Redis），从"无 docker 的 Xray 节点"变为"完整 stateful 节点"，备份/恢复/监控复杂度上升。
- bifrost-api 跨 wg0 调用 B 上的 NewAPI admin API（替代原本的 127.0.0.1:3000）。

### D2 — NewAPI 数据迁移策略 = 绿启（不迁移）  [2026-05-19]

**Context**：用户判断当前 A 上 NewAPI 数据量小且非关键，倾向重建。

**Decision**：B 上部署全新 NewAPI 实例，新建管理员账号、token、渠道。**A 上现 NewAPI 数据冷备保留 30 天**（pg_dump 到 `/var/backups/newapi-final-snapshot-YYYYMMDD.sql` + restic 推 B），30 天后人工清理。

**Consequences**：

- 无 cutover 窗口、无 PG 复制、无停机告警 → operate complexity 显著下降。
- 团队成员需要**手动重建账号**：作为本任务交付物，提供"团队成员重建 NewAPI 账号指引"文档。
- A 上现有 NewAPI **不再接受新写入**（迁移完成日起设为只读 / 关停），避免数据双写脏分裂。
- 已配置在 cc-switch / 客户端中的 NewAPI key **全部作废**，需要团队成员重新生成（已纳入交付清单）。
- 长期看：成功的"绿启演练"为未来 NewAPI 多次重建场景立标杆 SOP。

### D3 — A↔B TLS 拓扑 = α（A L7 终止 + wg 明文）  [2026-05-19]

**Context**：A 作 hub，需把私钥集中管理；Verdaccio 必须收到 `X-Forwarded-Proto: https` 才能生成正确 tarball URL（research/03 已述）；caddy-l4 仍 experimental。

**Decision**：

- **A 上 Caddy** 持有 TLS 证书：`/etc/caddy/certs/uuhfn-cloud-origin.{pem,key}`（Cloudflare Origin CA）或 LE 通配证书。
- **A → B 反代走 wg 明文**：`reverse_proxy http://10.8.0.2:3000 / :4873 / :8081 / :8082` 等。
- **wg 隧道本身的加密**视为足够的密文层；不引入 mTLS（v2 可选）。
- **B 上服务**全部 `bind 10.8.0.2`（仅 wg0 接口），nftables `iifname "wg0"` 放行；公网入站除 `udp/51820` 与 `tcp/22` 外全部 drop（22 走 wg0 + 白名单 IP set 双通道）。

**Consequences**：

- 私钥单点集中 A → 备份/轮换/告警都集中。
- B 上无需任何证书生命周期管理（除 internal CA 的 root cert 备份）。
- wg 抖动 = 全链路抖动；A 端 Caddy 需配 `health_uri` + `lb_try_duration 2s` 容忍秒级抖动。
- 团队成员永远只跟 A 的证书打交道。

### D4 — Windows VPS 处置 = 迁移完成后下线  [2026-05-19]

**Context**：B 上服务稳定运行 7 天即可下线 Windows VPS，避免持续付费 + 双向同步运维负担。

**Decision**：

1. T+0：B 上栈完成部署 + DNS 切到 A。
2. T+7：Windows VPS Verdaccio storage 通过 rsync over wg 复制到 B 上 `/var/lib/verdaccio/.legacy-snapshot/`（只读冷备）。
3. T+8：Windows VPS 关机退订。
4. 退订前在 `prompts/0519-1/post-migration/` 留下 final-snapshot.tar.gz（Verdaccio storage + caddy 配置 + git mirror tarball）的下载链接，30 天后人工清理。

**Consequences**：成本立即下降，B 单点风险加重（缓解：restic 推 A）。

### D5 — 运维入口 = CLI 主 + bifrost-api 只读 dashboard  [2026-05-19]

**Context**：所有写操作仍走 shell 脚本（与项目主路径一致），但 bifrost-api 加只读路由提升可观测性。

**Decision**：

- **写操作**全走 CLI：
  - `bash scripts/server-b.sh --enable-distribution` 一键开启 npm/files/git mirror + NewAPI
  - `bash scripts/server-b.sh --disable-distribution` 关闭
  - `bash scripts/diagnostics.sh --check distribution` 健康自检
  - systemd unit / timer 处理 `git-mirror@.service`、`verdaccio-backup.service`
- **读操作**进 bifrost-api（FastAPI on A，跨 wg 调 B）：
  - `GET /mirrors/status` → Verdaccio uptime / 最近同步时间 / git mirror 最新 commit
  - `GET /mirrors/logs?service={verdaccio|git-sync|newapi}` → 尾部 200 行日志
  - `GET /mirrors/disk` → B 上 `/var/lib/verdaccio` 与 `/var/lib/postgresql` 用量
  - 复用 bifrost-api 现有鉴权（不引新认证机制）

**Consequences**：

- bifrost-api 路由 `+3~4` 个只读 endpoint，约 +200 行 Python。
- 跨 wg 的 HTTP 调用需在 bifrost-api 端加 `BIFROST_SERVER_B_WG_IP` 环境变量。
- 故障定位流程：bifrost-api dashboard 发现异常 → SSH 到 A → wg 跳到 B → shell 修。

---

## Research References

- [`research/01-vpn-reverse-proxy.md`](research/01-vpn-reverse-proxy.md) — WG hub-and-spoke + Caddy L7 终止；不上 caddy-l4。
- [`research/02-linux-git-mirror.md`](research/02-linux-git-mirror.md) — MVP：systemd timer + nginx smart HTTP；中期可上 Gitea。
- [`research/03-verdaccio-linux.md`](research/03-verdaccio-linux.md) — Verdaccio v6.7.1 容器化 + `VERDACCIO_PUBLIC_URL` 强制 + restic 备份。

---

## Technical Notes

### 影响文件预测

| 文件 | 改动量预估 |
|---|---|
| `scripts/server-b.sh` | +400~600 行（新 `enable_distribution` 子命令 + idempotent 检查） |
| `scripts/server-a.sh` | +50~100 行（Caddy 反代规则 + WG peer 配置） |
| `configs/caddy/Caddyfile-a.tpl` | +20~40 行（npm/files/git 三段 reverse_proxy） |
| `configs/caddy/Caddyfile-b.tpl` | +30~50 行（B 上 Caddy 监听 wg0、proxy 到 Verdaccio/git-http-backend） |
| `configs/verdaccio/config.yaml.tpl` | 新增（约 80 行） |
| `configs/nftables/distribution.nft.tpl` | 新增（约 60 行，B 上严格白名单） |
| `scripts/diagnostics.sh` | +40 行（distribution 健康检查项） |
| `docs/USAGE.md` / `docs/SECURITY.md` | +100~150 行 |

### 风险矩阵

| 风险 | 等级 | 缓解 |
|---|---|---|
| 与 05-19-server-a-hardening-v2 PR-3 合并冲突 | 高 | 本任务等 PR-3 合入 main 后再启动 implement 阶段 |
| Verdaccio 公网→私网迁移导致团队 npm install 短暂失败 | 中 | 灰度切换：先双跑 Windows VPS + B，DNS 切换后再下线 |
| WG 链路抖动放大故障 | 中 | A 端 Caddy 加 `lb_try_duration 2s` + healthcheck；B 端 keepalive |
| restic 备份占满 A 磁盘 | 低 | retain 策略 + alert（A 磁盘 >80% 触发） |

### GitNexus 影响分析（待 implement 阶段前执行）

```
gitnexus_impact({target: "deploy_server_b", direction: "upstream"})
gitnexus_impact({target: "setup_caddy_a", direction: "upstream"})
gitnexus_context({name: "_save_deploy_state"})
```

---

> **下一步**：用户回答 Q1（MVP 范围分流）后，本 PRD 进入第二轮迭代，Q2-Q5 顺序展开。
