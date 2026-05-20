# Server B 承接能力 vs v2 审查

> 评估对象：v2 把 New API + DB + npm/docker/gh/hf/dl 全镜像下沉到 Server B，公网 443 跑 Xray Reality，3x-ui 收回 wg0。
> 真实文件采样：`scripts/server-b.sh` (2611 行)、`configs/caddy/Caddyfile-b.tpl`、`configs/xray/server.json.tpl`、`scripts/bifrost-api.sh`、`bifrost-api/`、`ai-gateway-bridge/`、根 `README.md`、commit `f90a229`。

---

## 1. 当前 B 角色（事实切片）

`scripts/server-b.sh` 真实部署的内容（按函数顺序）：

| 函数 | 行号 | 作用 |
|---|---|---|
| `install_xray_server` | L242 | Xray VLESS+Reality 服务端，listen 默认 8443，提示与 Caddy 80/443 冲突时改非 Web 端口 |
| 安装 3x-ui | L601 | 跑官方 `mhsanaei/3x-ui` 一键脚本；`vpn-first` profile 下不开公网端口，靠 Caddy `/xui-panel/` 反代 |
| `setup_caddy_b` | L1105 | 装 Caddy 写 `Caddyfile`（来源是脚本内联渲染，模板 `Caddyfile-b.tpl` 仅作 parity fixture） |
| `setup_whitelist_routing` | L1603 | nftables 白名单 |
| `enable_bbr` | L1906 | 内核调优 |
| `deploy_server_b` | L2134 | 入口 orchestrator |

**`Caddyfile-b.tpl` 实际只反代两个目标**：
- `localhost:{{PANEL_PORT}}` → 3x-ui 面板（`/xui-panel/*`）
- `/var/www/html` → 伪装静态站（任意未匹配路径）

`configs/xray/server.json.tpl` 没有任何 inbound 路由到 New API/PG/npm/docker mirror，只有 `vless-reality-in` + 出向白名单（35+ AI 域名直连，其余 block）。

**`grep 'docker compose\|docker-compose' scripts/server-b.sh` 结果 = 0**。Server B 完全没有 Docker 化服务。所谓"AI 域名白名单"只是 Xray 出向规则，**B 不解封装也不缓存**。

**`ai-gateway-bridge/`**：根目录 README 第 3 行明确声明"是旧目录名保留的历史子树，当前主实现以仓库根目录为准"。内部 `install.sh` 24808 字节，是 v2.0 历史快照。不应纳入新规划。

**`bifrost-api/`**：FastAPI 服务，封装 New API 的 REST 管理端点，对外通过 Caddy `/manage/*` 暴露。`scripts/bifrost-api.sh` L74 `BIFROST_API_DIR=${_BA_PROJECT_DIR}/bifrost-api`、L76 `BIFROST_API_PORT=8000`。**当前部署在 Server A**，Caddyfile-a L201 `reverse_proxy 127.0.0.1:8000`。

---

## 2. New API 迁 B 的成本

**当前位置**：`scripts/server-a.sh` L37 `NEW_API_DIR="/opt/new-api"`，L1306 `install_new_api()` 完整 docker compose 编排（SQLite 或 PostgreSQL + Redis）。`f90a229` 刚把这部分硬化：强制 `BIFROST_NEW_API_IMAGE` 不带 `latest`、PG 密码不漂移、3000 端口只绑 127.0.0.1。

**迁 B 的工程量**：
1. **代码搬移**：把 `install_new_api / prepare_new_api_env / verify_new_api_port_binding / diagnose_new_api_startup_failure` 这一族（约 1100-1500 行）从 `server-a.sh` 拷到 `server-b.sh`，包含 `.env`、postgres-data、redis-data、data 四个 volume。`bifrost-api`（FastAPI 容器，依赖 New API 的 admin token，见 `bifrost-api/README.md`）必须**跟着搬**，否则跨墙 admin API 调用每次都要穿 Reality 隧道。
2. **数据迁移**：现有部署 `${NEW_API_DIR}/postgres-data` 含用户、quota、调用日志。一刀切迁移有数据丢失风险，必须 `pg_dump` + `BIFROST_NEW_API_POSTGRES_PASSWORD` 显式注入（`server-a.sh` L1217 已对此报错保护）。
3. **链路反转**：员工调用 `api.mirror.lan/v1/chat/completions` 走向：
   ```
   员工 → WG → A:wg0 → Caddy(A, internal) → 127.0.0.1:10800 (Xray client)
     → VLESS+Reality → B:443 (Xray server) → 解封装 → Caddy(B) → 127.0.0.1:3000 (New API)
     → upstream Claude/OpenAI
   ```
   对比 v1（New API 在 A）：员工 → WG → A:wg0 → Caddy(A) → 127.0.0.1:3000，**少 1 跳跨境 + 1 次 Reality 加解密**。
4. **延迟**：A→B 中美跨境 RTT 通常 180-280ms；New API 是聊天接口、流式响应，首 token 延迟会从 ~600ms 涨到 ~900ms+，但稳态 throughput 几乎不变（Reality 走 mux 后单连接复用）。
5. **故障域**：B 一旦被海外机房抽风/IP 漂移，国内员工的 New API 控制台、bifrost-api 注册页（`/manage/register`）**同时挂**，目前是只挂转发。

---

## 3. 新增镜像服务（v2 隐含的最大盲点）

战略文档 §3 Caddyfile 模板里写满了 `npm.mirror.lan / docker.mirror.lan / gh.mirror.lan / hf.mirror.lan / portal.mirror.lan`，反代目标统一 `127.0.0.1:10800`（A 上 Xray dokodemo），出向到 B:443。但文档 §11 只说"B 端是 server-b.sh 原流程（含 3x-ui + Reality + Caddy + 各镜像 docker-compose）"——**实测仓库里 `server-b.sh` 里根本没有任何 docker-compose 镜像服务**（§1 已验证）。这是一个未实现的承诺。

**镜像层选型缺失，必须明确**：

| 服务 | 推荐方案 | 资源占用预估 | 难点 |
|---|---|---|---|
| **npm 镜像** | Verdaccio（轻量代理+缓存）；不推荐 Nexus（Java，2GB+ heap） | 100-300MB RAM；缓存盘 50-200GB | 私有包不需要时仅缓存代理即可，配 `uplinks: registry.npmjs.org` |
| **docker 镜像** | `registry:2` (distribution) + `proxy.remoteurl=https://registry-1.docker.io` | 100MB RAM；缓存 200GB-1TB（含 layer blob） | Docker Hub 限流，需匿名 token 池；大公司用 Harbor 但太重 |
| **gh 镜像** | 仅 reverse_proxy 透传到 `github.com` / `objects.githubusercontent.com`，不存盘 | <50MB（纯反代） | LFS / release 二进制可能 GB 级，不缓存就每次穿墙 |
| **hf 镜像** | Caddy 反代 + 可选 `huggingface_hub` 本地缓存挂盘 | 50MB 反代 + LFS 缓存 500GB-数 TB | 海外 LFS 单文件常 5-20GB，B 带宽和入站流量帐单爆炸 |
| **通用 dl 镜像** | Caddy `file_server` + 手动 prefetch，或直接 reverse_proxy | 视内容 | 缺乏管控易被滥用 |

战略文档**完全没决策**这些组件，相当于规划阶段把 `docker-compose.yml` 全部留白。

---

## 4. 硬件需求矩阵

| 角色 | README 当前 | v2 实际需要 | 增量原因 |
|---|---|---|---|
| Server B CPU | 1 核 | 8 核 | New API（Go，4 worker）+ PG + Verdaccio + registry + Caddy + Xray Reality + 3x-ui |
| Server B RAM | 1 GB | 16 GB | New API 500MB + PG 1-2GB + Redis 200MB + Verdaccio 300MB + registry 300MB + Caddy 200MB + Xray 200MB + 系统/缓存 buffer 2-4GB + Mihomo geodata（若按 §6 在 B 也跑）500MB |
| Server B 存储 | 20 GB SSD | **500 GB - 2 TB SSD** | docker layer 缓存 ≥500GB；hf LFS ≥500GB；New API PG 日志/quota ≥50GB |
| Server B 带宽 | 30 Mbps | **100-200 Mbps + 不限流量** | docker pull/hf clone 单次几 GB；多员工并发挤死 30M |
| 月成本（按 vultr/hetzner） | ~5-8 USD（Bandwagon/RackNerd） | **80-180 USD**（Hetzner CCX33 / Vultr High-Performance） | 翻 10-20 倍 |

README L77-85 必须同步改：推荐商家从 Bandwagon/RackNerd（VPS 小机）→ Hetzner CX 系列 / Vultr HP / DigitalOcean Premium。**且单机 SLA 风险变大，应规划主备**。

---

## 5. ai-gateway-bridge / bifrost-api 角色

- **`ai-gateway-bridge/`**：历史快照，不应在 v2 规划中复活。建议在 v2 落地前**把它移到 `archive/` 或直接删除**，否则新维护者会误读为现行实现。
- **`bifrost-api/`**：当前 Caddyfile-a L185-217 路由 `/manage/*` → `127.0.0.1:8000`。它**只调用 New API 的 admin API**，本质是 New API 的 UI 外壳 + 用户注册自服务。逻辑上必须**跟随 New API 走**：New API 迁 B 则 bifrost-api 也迁 B；否则 `/manage/register` 每次注册都要绕一圈 A→B→A。bifrost-api 内存仅 ~80MB，搬不是问题，**关键是 Caddyfile-a 的 `/manage/*` 反代目标要从 `127.0.0.1:8000` 改成 `127.0.0.1:10800`（即走 Xray 隧道到 B:8000）**。

---

## 6. 部署顺序冲突

战略文档 §12 Phase 顺序：
- Phase 2 = Server A 极简栈（含 §14 步骤 14 `Xray 装 + outbound 配 + systemd service`）
- Phase 3 = Server B 全栈（步骤 21-23）

**冲突**：A 的 Xray client outbound 配置（`server.json.tpl` outbound 段）需要 B 的 Reality `publicKey` / `shortId` / `UUID`。这些值由 `server-b.sh` L286-289 `Generating X25519 keypair for Reality` 在 B 部署时生成，再通过 `_save_deploy_state XRAY_SNI / XRAY_REALITY_DEST`（L504-505）落盘。如果先 A 后 B：A 启动 Xray 时拿不到 B 的 pubkey/UUID，systemd 服务会 crashloop，TLS 隧道全断 → A 的 Mihomo 路由出口失效 → wg0 内的员工连不通任何域名。

**正确顺序**：Phase 0（DD）→ Phase 1（系统基线 两机并行）→ **Phase 2 = Server B**（生成 Reality 凭据并通过安全通道导出 `state.env`）→ **Phase 3 = Server A**（注入 B 的凭据，启动 Xray client）→ Phase 4 联调。战略文档 §12 步骤 14 与步骤 22 顺序必须互换。

---

## 7. 回退 / 灰度策略

一刀切迁移在 v2 的复杂度下不可接受（涉及 PG 数据、镜像缓存预热、bifrost-api 配置、Caddy 路由四处同时改）。推荐**双轨灰度 3 周**：

| 周次 | 状态 | 切流方式 |
|---|---|---|
| Week 0 | A 上 New API + bifrost-api 保持运行；B 仅 Reality | baseline |
| Week 1 | B 上同时启 New API + bifrost-api（不同 PG 实例），用 `pg_dump \| restore` 把 A 的库克隆到 B；员工凭据/quota 静默同步 | A 仍承接全部流量 |
| Week 2 | Caddyfile-a `/manage/*` 和 `api.mirror.lan` 用 Caddy `handle` 加 5% 流量灰度到 `127.0.0.1:10800`（→B） | 灰度 5% → 25% → 50% |
| Week 3 | 100% 流量到 B；A 上 New API 容器停止但**保留数据卷**直到 Week 5 | 观察期 |
| Week 5 | 确认 B 稳定后，`docker compose down -v` 清掉 A 的 PG | 终止双轨 |

镜像服务（npm/docker/hf）属于**全新组件**，无回退包袱，直接在 B 上部署即可，但要分批：先 npm（缓存最容易，回收快） → docker（中等） → hf（流量最大，必须先压测）→ gh（透传，最后）。portal.mirror.lan 在 A 上即可静态站，无需迁 B。

---

## 附：审查时发现的额外风险

1. **3x-ui 收 wg0 与 Reality 公网 443 冲突未处理**：当前 `install_xray_server` L331 `Port 8443 conflicts with Caddy web entrypoints` 提示与 Caddy 同时跑在 443/8443 时端口冲突。v2 想把 Reality 放 443 + Caddy 也在 443（在 Reality 解封装之后）——必须用 Xray 的 `fallback` 段把非 Reality TLS 流量回落到 Caddy 的 `127.0.0.1:8443`，**目前 `server.json.tpl` inbound 段没有 `fallbacks` 字段**，需要补。
2. **`Caddyfile-b.tpl` 是 parity fixture**：脚本运行时用的是 `server-b.sh` L1168 的内联 heredoc，不是模板。任何 v2 改动必须**两处同步**，否则 `tests/test-in-docker.sh` 的 parity check（模板顶部注释 L11-13 写明）会红。
3. **f90a229 commit 的硬化逻辑只在 A**：`feat: harden new api one-click deployment` 改的全是 `scripts/server-a.sh`。一旦迁 B，所有这些保护（image 不可变、PG 密码漂移检测、端口绑定校验）必须**完整复制到 server-b.sh**，否则等于回退到硬化前状态。
