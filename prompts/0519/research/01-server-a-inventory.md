# Server A 当前实现 vs v2 战略冲突清单

> 审查范围：`scripts/server-a.sh` (3328 行) · `configs/caddy/Caddyfile-a.tpl` (258 行) · `scripts/security.sh` (setup_firewall) · `scripts/vpn.sh` (WG 端口/子网) · `install.sh` · `README.md` · 近 5 个 commit。
> 战略基准：`prompts/server-a-hardening-strategy.md` v2（公网零 80/443，Caddy 内迁 wg0，New API 迁 B，ACME 去除）。

---

## 1. 重大冲突（必改）

| # | 冲突点 | 当前实现位置（file:line） | v2 要求 | 改动幅度 | 优先级 |
|---|---|---|---|---|---|
| C1 | **公网 80/tcp 无条件开放** | `scripts/security.sh:645-646`（ufw allow 80/tcp 注释 "HTTP (cert renewal)"）+ `:714-716`（firewalld add-service=http） | 公网零 80/tcp，触发腾讯云 ICP L7 DPI 即死 | 中 | **P0** |
| C2 | **公网 443/tcp 无条件开放** | `scripts/security.sh:642-643`（ufw allow 443/tcp）+ `:710-712`（firewalld add-service=https） | 公网零 443/tcp，SNI 监测命中即 RST | 中 | **P0** |
| C3 | **Caddy 默认绑定公网域名/公网 IP** | `scripts/server-a.sh:1644-1880`（`${site_address} { ... }` 块内联渲染，未带 `bind` 指令，缺省监听 0.0.0.0:80/443）+ `Caddyfile-a.tpl:53`（`{{DOMAIN}} {`） | `bind 10.8.0.1` + 仅监听 wg0；改 `*.mirror.lan` 站点块 | 大 | **P0** |
| C4 | **三种 TLS 模式全部走公网 ACME/CF Origin** | `scripts/server-a.sh:194-211` 定义 `domain/cloudflare-origin/ip` 三模式，**无 `internal`/`local-ca` 选项**；`:316-501` 内置 certbot snap 安装 + Let's Encrypt IP shortlived 证书 + 续期 timer | 删 Let's Encrypt / Cloudflare DNS-01 外联，改 `tls internal`（Caddy local CA） | 大 | **P0** |
| C5 | **New API + PostgreSQL 全栈部署在 A** | `scripts/server-a.sh:37`（`NEW_API_DIR="/opt/new-api"`）+ `:1306-1572`（`install_new_api` 含 docker compose、PG 数据卷、健康检查）；`deploy_server_a` Step 6 强制 `install_new_api`（`:3032-3036`，失败直接 `return 1`） | New API 迁 B；A 上仅 Xray 出向，反代回 B | 大 | **P0** |
| C6 | **ACME HTTP-01 bootstrap 强依赖 TCP/80** | `scripts/server-a.sh:421-501`（`bootstrap_ip_certificate` 启临时 `:80` 站，:80 challenge）；`:488`（错误信息要求 TCP/80 必须可达）；`:1613`（运行期警告"TCP/80 must stay reachable for renewal"） | 删整段；改用 Caddy `tls internal` 自动滚动 | 大 | **P0** |
| C7 | **公网伪装站直接挂 Caddy 公网入口** | `scripts/server-a.sh:1654-1695`（公网 `handle / { root * /var/www/html ... }`）+ `:2083-2700+`（`setup_decoy_website` 生成 CloudTech Solutions 假站）+ `Caddyfile-a.tpl:222-235` | 伪装站重定义为内网门户 `portal.mirror.lan`，员工 VPN 内访问 | 中 | **P0** |
| C8 | **WireGuard 默认端口 51820/udp** | `scripts/vpn.sh:51`（`readonly WG_PORT=51820`）+ `:415`、`:910`、`:1199` | v2 §2.1 要求避开 51820 等熟知端口，30000-65000 范围随机 + 持久化 `/etc/bifrost.env` | 小 | **P1** |
| C9 | **`setup_firewall` 对 exposure_profile 零感知** | `scripts/security.sh:576-679`（grep 全文 0 处 `exposure_profile` / `vpn-first` 引用） | vpn-first 必须收掉 80/443，只留 WG UDP + SSH | 中 | **P0** |
| C10 | **vpn-first profile 名不副实** | `scripts/server-a.sh:1712-1789`（vpn-first 分支仍渲染 `/v1/*` 公网 + `/api/status` 公网，只是把 dashboard/manage 加 `remote_ip` 白名单 403）；`Caddyfile-a.tpl:113-167` 同样 | v2 要求 vpn-first 不挂任何公网站点，连 `/v1/*` 都仅 wg0 | 大 | **P0** |

---

## 2. 次级冲突（应改）

| # | 冲突点 | 当前实现位置 | v2 要求 | 幅度 | 优先级 |
|---|---|---|---|---|---|
| S1 | SSH 仍走 22 端口（或安装时改的随机端口），未引入"公网 60022 + 内网 22"双通道 | `scripts/security.sh` `_get_ssh_port` 取系统现状；`bifrost_admin_allowed_ranges` 仅作 Caddy `remote_ip` 白名单，未传递到 nftables | v2 §2.1：公网 60022 + admin IP allowlist；内网 wg0:22 与公网分流 | 中 | P1 |
| S2 | 仍用 ufw/firewalld，缺 nftables 严格模板 + log prefix + meter 限速 | `scripts/security.sh:_setup_firewall_ufw / _setup_firewall_firewalld` | v2 §5 提供完整 `table inet bifrost` 规则集 | 中 | P1 |
| S3 | fail2ban 默认对 Caddy 公网做 403 暴破守护（`caddy-internal-403` 在 v2 中被关闭） | `scripts/security.sh:setup_fail2ban`（间接引用） | v2 §8：caddy-internal-403 关闭，wireguard jail 关闭，仅守 SSH | 小 | P2 |
| S4 | Caddy 全局 `email admin@{{DOMAIN}}`（暗示 ACME 注册） | `Caddyfile-a.tpl:31-32` + `scripts/server-a.sh:1644+`（生成时无 email 行，已部分缓解） | v2 §3.1：`email admin@mirror.lan`，纯本地 | 小 | P2 |
| S5 | Mihomo `external-controller` / dnsmasq 监听位置文档未与 wg0 对齐 | `scripts/server-a.sh` Step 5 调用 `mihomo.sh`（未审）；当前 README/USAGE 无 `bind-address: '10.8.0.1'` 强调 | v2 §6：Mihomo 仅 wg0；dnsmasq 53 + Mihomo 5353 协作 | 小 | P2 |
| S6 | 客户端 bundle 未带 Caddy local CA 根证书分发 | `scripts/user-management.sh`（v2 §13.5 要求 `generate_client_bundle` 含 `bifrost-root.crt`） | v2 要求一次性 bundle | 中 | P2 |
| S7 | `BIFROST_CERTBOT_INSTALL_METHOD` / `BIFROST_LETSENCRYPT_STAGING` / `BIFROST_CLOUDFLARE_ORIGIN_CERT` 等 6+ 个变量在 v2 下变成死代码 | `scripts/server-a.sh:248-501` | 删除或迁 `legacy/` 目录 | 中 | P1 |
| S8 | `validate_domain_name` 强制 ICP 备案警示 | `scripts/server-a.sh:239`（"must be ICP-registered"提示） | v2 下根本不要域名，`*.mirror.lan` 用 mDNS/局域命名 | 小 | P2 |

---

## 3. 与 v2 一致或部分匹配的现状（可复用）

- **架构定位**：README:28-46 + install.sh:6-10 已声明"员工设备 → WireGuard VPN → Server A"，VPN-first 概念在文档层面已落地。
- **`bifrost_exposure_profile` 抽象**：`scripts/common.sh:50-89` 已抽出 `vpn-first/public-managed/lab` 三档枚举 + `BIFROST_ADMIN_ALLOWED_RANGES` 白名单，是 v2 §0 "三大设计约束"在代码侧的雏形，**仅需把 vpn-first 语义从"管理面 allowlist"升级到"全面 wg0-only"**。
- **Caddy `@manage_private` / `@newapi_private` `remote_ip` 匹配器**：`server-a.sh:1722-1781` + `Caddyfile-a.tpl:151-219` 提供了 admin 白名单 -> 403 fallback 的成熟样板，v2 内迁 wg0 后这套 matcher 仍可直接用于 wg0 子网。
- **Xray 客户端架构**：`scripts/server-a.sh:592-1057` `install_xray_client` 已实现 dokodemo-door + Reality 出向 + Mihomo 联动，与 v2 §7 完全一致，**0 改动**。
- **Mihomo 部署**：`deploy_server_a` Step 5 调用 `mihomo.sh`（v2 §6 复用），路由角色保留。
- **WireGuard 拓扑**：`vpn.sh:44-51` 已用 `10.8.0.0/24` + `10.8.0.1` 网关，与 v2 §2.2 完全一致。
- **dd-reinstall 云审查 gate**：`server-a.sh:2923-2942` 已强制 `cloud_review_blocks_deployment` 才能继续，v2 可继续利用此 gate 拒绝在腾讯云上跑 public-managed。

---

## 4. 与近期 commit 的矛盾

### 4.1 `9877b12 feat: support IP HTTPS for server A`（460+ 行新增 server-a.sh）

该 commit 整体引入 `ip` TLS 模式 + certbot snap 安装 + LE shortlived IP cert + bifrost-certbot-renew.timer。**v2 §1.3 表格明确把"公网纯 IP HTTPS"列为缺陷路径**（"客户端必须 OS 级支持 IP cert SAN，npm/docker 客户端不可靠；几天后仍可能被识别封"），并在 §13.1 改动清单中标 `- configure_acme_renewal`（删除）。

**矛盾要点**：
- 9877b12 投入 ~300 行实现 Let's Encrypt IP shortlived 证书自动续期（`server-a.sh:316-501`），v2 直接删；
- 9877b12 在 `Caddyfile-a.tpl:60-70` 引入 `{{TLS_CERT_FILE}}` / `{{CLOUDFLARE_ORIGIN_CERT_FILE}}` 三模板分支，v2 只留 `tls internal` 一支；
- 9877b12 的设计前提是"公网仍能跑 443/tcp"，与 v2 §1 证据链根本对立。

**规划必须显式回答**：为何在 1 周内推翻 IP HTTPS 路径？建议回答框架：
1. 9877b12 假设"非备案 IP HTTPS"能绕过腾讯云 L7 监测，但 V2EX 1082505 实测+腾讯云官方文档证明 SNI/Host 在任意端口都被 DPI，IP cert 只解决"客户端信任"问题、不解决"运营商发 RST"问题。
2. LE shortlived（profile=shortlived）证书短期内可能下线（仍是 RFC draft 状态），运维成本不收敛。
3. IP cert SAN 在 Node/Go/Python HTTP 客户端落地不一致（v2 §1.3 第一行已点出）。

### 4.2 `04be5ac fix: harden cloud review deployment gates`（820 行 dd-reinstall.sh 改动）

该 commit 引入 `cloud_review_blocks_deployment` / `CLOUD_REVIEW_DEPLOYMENT_BLOCK_REASON` 拒绝部署机制，本质是**让运维人手在腾讯云上跑流程时遭遇"备案/合规风险阻断"**。

**与 v2 关系**：方向一致但深度不够。04be5ac 只是"检测到腾讯云未备案就拒绝部署 public-managed"，v2 主张"无论什么云，国内 Server A 默认 `private-internal` profile，根本不让 80/443 公网出现"。v2 §18.6 明确建议 `scripts/cloud-detect.sh` 识别国内云**强制** `private-internal`。

**矛盾要点**：04be5ac 仍保留 public-managed 作为合法路径，意味着仍有"开 443 公网"的部署分支存活；v2 应该把 public-managed 降级为 `lab-only`。

---

## 5. 改动量估算

| 文件 | 删除（行） | 新增（行） | 净 |
|---|---|---|---|
| `scripts/server-a.sh` | ~520（`install_certbot_ip_support` ~60 / `configure_ip_certificate_renewal` ~45 / `bootstrap_ip_certificate` ~80 / `server_a_ip_http_challenge_block` ~25 / `install_new_api` 全段 ~270 / `prepare_new_api_env` ~70 / Caddy 双分支冗余 ~80） | ~280（`setup_caddy_a_internal` ~180 / `setup_portal` ~50 / WG 端口随机化 ~30 / nftables 严格模板调用 ~20） | **-240** |
| `configs/caddy/Caddyfile-a.tpl` | 替换 vs 新增并存。**建议保留为 legacy 模板**（重命名 `Caddyfile-a-public-decoy.tpl.legacy`，加 README 警告），新增 `Caddyfile-a-internal.tpl` 100 行 + `portal.html.tpl` | — | 净 +100 |
| `scripts/security.sh` | ~10（80/443 无条件 allow 删除） | ~60（按 exposure_profile 分支 + nftables-strict 模板调用） | +50 |
| `scripts/vpn.sh` | 1（`readonly WG_PORT=51820`） | ~25（`shuf` 随机化 + `/etc/bifrost.env` 持久化 + AmneziaWG 占位） | +24 |
| `scripts/user-management.sh` | — | ~60（bundle 含 root.crt + 多镜像 hosts/.npmrc/daemon.json 模板） | +60 |
| `Caddyfile-b.tpl` / `server-b.sh` | — | 接收从 A 迁出的 New API 站点块 ~150 | +150 |

**配置变量重命名建议**：
- `BIFROST_SERVER_A_TLS_MODE`：保留枚举值改为 `internal`（默认）/ `internal-with-cf-dns01`（可选）/ `legacy-domain` / `legacy-ip`。后两项写文档警告，运行时打 deprecation。
- `BIFROST_EXPOSURE_PROFILE`：保留 `vpn-first`/`public-managed`/`lab`，但把语义升级：vpn-first ⇒ Caddy 仅监听 wg0，security.sh 不开 80/443。
- 新增 `BIFROST_WG_PORT` / `BIFROST_WG_OBFUSCATION`（v2 §13.1）。
- 新增 `BIFROST_ADMIN_SSH_PORT`（默认 60022）/ `BIFROST_ADMIN_SSH_ALLOWLIST`。
- 弃用 `BIFROST_CERTBOT_INSTALL_METHOD` / `BIFROST_LETSENCRYPT_STAGING` / `BIFROST_ACME_EMAIL`，加 deprecation 警告。

---

## 6. 风险标记（破坏面 Top 5）

1. **现网有备案用户被迁移破坏**：若把 vpn-first 升级为"wg0-only"作为默认，所有已用 `domain` / `cloudflare-origin` 模式跑 production 的用户，再跑一次 `--server-a` 会丢公网 `/v1/*` 入口。**缓解**：保留 `BIFROST_EXPOSURE_PROFILE=public-managed` 作为兼容路径，但首屏 banner 严厉警告；新增 migration guide。

2. **IP HTTPS 用户证书续期立即中断**：删 `bifrost-certbot-renew.timer` 后，老用户的 LE shortlived IP cert 7 天内全部过期。**缓解**：升级脚本检测到 `/root/server-a-domain.conf` 中 `ENDPOINT_MODE=ip` 时，强制走"显式弃用提示 + 一键回滚 / 一键迁 vpn-first"两路。

3. **伪装站消失对未启用 VPN 的诊断访问影响**：现网用 `curl https://A_IP/` 看到 CloudTech Solutions 假站（`server-a.sh:2099+`）的运维脚本/同事会迅速发现"网站没了"。**缓解**：vpn-first 模式下，公网 nmap 已经看不到 443，本来就不该有 curl 路径；但 README/USAGE 必须显式新增"如何在 v2 模式下做健康检查"章节（v2 §15 验证清单可直接借用）。

4. **"伪装站重定义"在概念上偷换**：v2 §3.2 把"伪装站"语义从"抗主动探测"换成"员工内网门户"。这是**概念偷换**，不是同一个安全控制——抗主动探测的对象是 GFW/外部扫描，员工门户的对象是公司内部 UX。建议在 v2 文档里坦诚：v2 模式下"伪装"这一安全特性**被彻底放弃**，因为公网根本看不到 Caddy 就不需要伪装；保留的 portal.mirror.lan 是新 feature，不是旧 feature 的延续。否则会让审计方误以为"伪装能力还在"。

5. **WG UDP 高位端口仍可能被腾讯云 UDP 流量画像识别**：v2 §14 风险表已自承"WG 高位 UDP 端口被腾讯云画像"（建议升 AmneziaWG L3）。但 v2 §2.1 又写"腾讯云对 UDP 高位端口监管最弱"——两处自相矛盾，需要在规划中给出口径：默认 Level 1 还是默认 Level 3。建议默认 Level 1（最快上线，零客户端改造），把 Level 3 作为"出现 DPI 后切换"的备份预案。

---

## 附：v2 战略本身的几个弱点（批判性提示）

- **`tls internal` 根证书分发是隐性"客户端侵入"**：每个员工设备需 `update-ca-certificates` / `add-trusted-cert` / `Cert:\LocalMachine\Root`。Windows 域控环境下，员工无管理员权限的情况非常常见。建议在规划阶段先评估"BYOD 员工是否有 admin 权限"。
- **§18.6 "国内云强制 private-internal"** 会破坏开源用户在阿里云/华为云做有备案企业内 AI 网关的合法用例（他们**有**备案，**应该**用 public-managed）。建议把"国内云强制 private-internal" 改为"国内云 + 未备案"两个条件齐备才强制。
- **§17 三角图"v2 ✦"标记在三角内部一个未命名点**，没有给出三轴坐标，看上去更像营销示意而非工程对照表。

> 文档版本：v1.0 · 2026-05-18 · 1980 字
> 上游基准：`prompts/server-a-hardening-strategy.md` v2
