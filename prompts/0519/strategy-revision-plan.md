# Server A 加固 v2 战略修订规划

> 日期：2026-05-19
> 上游：`prompts/server-a-hardening-strategy.md` v2.0
> 审查证据：`prompts/0519/research/01-06`（6 篇并行 agent 批判审查报告）
> 立场：**不建议全盘采纳 v2**。需先解决与 `9877b12` 公开矛盾、补齐方案 X/Y/Z 论证、明确产品定位。

---

## 0. 一句话结论

v2 是一份工程上精致、商业上错位、且**与项目 3 天前合并的 `9877b12`（460 行 IP HTTPS feature）公开矛盾**的方案。
最致命盲点：v2 把"国内云未备案"作为不可挑战的前提，但**腾讯云香港 Lighthouse 锐驰 2C2G 200Mbps 24 元/月免备案**（方案 X）让 v2 所有复杂改造在 80% 工作量上变成多余。

---

## 1. v2 决策矩阵（采纳 / 延后 / 否决）

### 1.1 应采纳（低风险 · 独立价值 · 即使换前提仍适用）

| 项目 | v2 章节 | 落地优先级 | 来源 |
|---|---|---|---|
| nftables 严格模板（policy drop + 显式 allow + log prefix + meter 限速） | §5 | P0 | research/02 §4 + research/06 §9 |
| 公网 SSH 端口非 22（已有，需加 admin IP allowlist） | §2.1 | P0 | research/02 §3 |
| WG ListenPort 30000-65000 高位随机化 + 持久化到 `/etc/bifrost.env` | §4.1 | P0 | research/02 §1 |
| fail2ban 仅守 SSH（关闭 `caddy-auth`、`caddy-botsearch`、`wireguard`） | §8 | P1 | research/02 §4 + research/01 表 S3 |
| Caddy `tls internal` 作为 **VPN 管理面**（不是业务面替代品） | §3.2 | P1 | research/01 表 S6 + research/06 §9 |
| journald 限额 + 转发到 B（审计基础设施） | §12 Phase 2-20 | P1 | research/06 §9 |
| Mihomo `bind-address: 10.8.0.1` + `allow-lan: false`（修当前 wg0 内开放代理 bug） | §6 | **P0**（独立安全 bug） | research/03 §1 |
| `rotate-dest.sh` 切换后联动 A 客户端 `SERVER_B_SNI`（独立 bug） | — | **P0**（独立 bug） | research/03 §6 |

### 1.2 应延后（需先验证前提）

| 项目 | v2 章节 | 阻塞条件 |
|---|---|---|
| AmneziaWG L3 混淆 | §4.2 | 先实测 vanilla WG 在腾讯云高位 UDP 是否真被针对（A/B 测试 4 周） |
| 镜像服务全部迁 B + B 升级 8C16G | §11 | 先评估方案 X（A 改香港云）把所有镜像放 A 的可行性 |
| 新员工 portal.mirror.lan 自助申请 | §3.2 + §14 | 产品定位（VPN-only 是否商业可接受）未明确前不动 UX |
| Caddy 全面内迁 wg0（业务面） | §3.1 | 与 9877b12 作者对齐 IP HTTPS 去留之前不动 |

### 1.3 应否决（不可逆 · 有更优替代 · 证据不足）

| 项目 | v2 章节 | 否决原因 |
|---|---|---|
| "公网零 HTTP/HTTPS、IP HTTPS 死路" 一刀切结论 | §1.3 | 与 9877b12 直接冲突；V2EX 1082505 用户实测 IP HTTPS **长期可用反例存在**（GuguDan/guanhui07）；证据链不充分 |
| 强制根 CA + 强制 VPN-only + 强制 awg-quick 客户端 三合一 | §3.2 + §13.5 | 与 README "一键部署、零运维" 产品定位严重冲突；用户步骤从 3 步突增到 9 步（research/04 §6） |
| "公网仅 1 UDP + 1 SSH 画像 = 隐蔽" 论断 | §10 | 在 2026-04 RFA 报道江苏运营商"翻墙业务"专项整治语境下，此画像**恰是被打击的特征**而非规避（research/06 §1.4 + §3） |
| 未与 9877b12 作者沟通即单方面宣判其代码"死路" | §13.1 | 反 Trellis 协作原则；架构委员会应 block 直到达成共识（research/06 §2） |

---

## 2. 战略前提批判要点（必读）

### 2.1 v2 vs `9877b12`（IP HTTPS）公开矛盾

| 项目 | `9877b12`（2026-05-15 合并） | v2（2026-05-18） |
|---|---|---|
| IP HTTPS 是否可行 | 是，**1059 行新增主 feature** | 否，"几天后被识别封" |
| 投入量 | 460 行 `server-a.sh` + 4 文档更新 | 直接判死刑 |
| 客户端兼容 | "用于真实测试链路" | "npm/docker 客户端不可靠" |
| 维护 | 8 小时一次自动续期 timer | 不需要 |

v2 §13.1 写 `- configure_acme_renewal` 但**完全没提**如何处理 `9877b12` 引入的 `install_certbot_ip_support` / `configure_ip_certificate_renewal`。这是文档完整性硬伤。

### 2.2 v2 ICP 监测证据被反向证伪

腾讯云原文（2025-04 更新）确实有 "不论设置哪个端口都能被监测到"，但：

- 原文是**备案义务**论证，不是**实测 RST**
- 没区分 HTTP/HTTPS/UDP/其它协议
- V2EX 1082505 帖里 **UDP 拦截无人报告**，IP HTTPS **GuguDan/guanhui07 报长期可用**
- 阿里云/华为云政策**与腾讯云不同步**，v2 过度概括

### 2.3 2026 真实风险被忽略

RFA 2026-04-09 报道：江苏运营商专项整治"违规跨境访问"，**对被通报的 IP 立即断端口**。
腾讯云用户报因"通过技术手段使其成为跨境访问节点"被封机。
**v2 把 A 改成"纯 UDP + SSH"画像，恰好命中风控特征**，触发了比"未备案"更高优先级的红线。

### 2.4 GFW 2026 已识别 vanilla WireGuard

多份 2026 GFW 现状报告：
- WireGuard 握手包指纹固定 `148 bytes + 92 bytes`
- 商业 DPI（Sandvine/Allot/华为）默认带 WG 检测规则
- **任意 UDP 端口标准 WG 60 秒内识别封禁**
- v2 §2.1 "腾讯云对 UDP 高位端口监管最弱" 与 §14 "WG 高位 UDP 被画像" **自相矛盾**

### 2.5 "伪装站"概念偷换

| v1 公网伪装 | v2 内网门户 |
|---|---|
| 抗主动探测（GFW/扫描） | 抗员工误用（UX） |

两个 "抗" 字针对的威胁模型完全不同。v2 用相同词重命名，**实质是放弃抗主动探测能力**而不坦诚承认。

---

## 3. 替代方案对比（v2 未讨论）

| 维度 | v2 方案 | **方案 X：换香港云**（推荐） | 方案 Y：保留有备案 + vpn-first 严格化 | 方案 Z：Cloudflare Tunnel |
|---|---|---|---|---|
| 核心做法 | 国内云 + WG-only 公网 + Caddy 内迁 | A 改腾讯云香港 Lighthouse / Vultr Tokyo | 保留 v1 + ICP 备案 + Caddy 公网 443 + vpn-first | A 不开公网，cloudflared 反向接入 |
| 备案合规 | 不触发但触发"个人 VPN"风控 | **完全不需要备案** | 完整 ICP 备案 | A 无对外端口 |
| 公网 UDP 暴露 | 1 个 UDP | 无（香港不限） | 无（走 443/tcp） | 无 |
| GFW WG 指纹 | 受影响（§2.4） | **无影响**，30-50ms 直连 | 无（TCP TLS） | 无 |
| 客户端配置 | WG + 根 CA + npmrc + daemon.json + git | 浏览器直连 | 浏览器 + WG | 浏览器直连 |
| 月成本 | A ¥80 + B $120 = **~$130/月** | A ¥24 + B $4 = **~$8/月** | ~$8/月 | A ¥80 + B $4 = ~$15/月 |
| 腾讯云风控封号风险 | **高**（§2.3） | 零 | 低 | 中 |
| 9877b12 兼容 | **冲突** | 自动兼容 | 不需要 | 不需要 |
| 非技术员工可用 | 差 | **好** | 好 | 好 |
| 30-100 人企业落地 | 难 | 易 | 易 | 中 |
| 回滚难度 | 极高 | 低 | 极低 | 中 |

**关键问题**：v2 文档对方案 X 完全沉默。规划阶段必须先回答："如果换香港云这些问题全都不存在，我们为什么坚持在国内云上做这件事？"

---

## 4. 项目路径冲突总览（按优先级）

### 4.1 P0 — 必须改

| # | 冲突点 | 当前位置 | v2 / 修订要求 | 来源 |
|---|---|---|---|---|
| C1 | 公网 80/tcp 无条件开放 | `scripts/security.sh:645-646`、`:714-716` | 按 `exposure_profile` 分支 | research/01 |
| C2 | 公网 443/tcp 无条件开放 | `scripts/security.sh:642-643`、`:710-712` | 同上 | research/01 |
| C3 | Caddy 默认绑 `0.0.0.0` | `scripts/server-a.sh:1644-1880`、`Caddyfile-a.tpl:53` | `bind 10.8.0.1` + 内网模板 | research/01 |
| C4 | 三种 TLS 模式全走公网 ACME | `scripts/server-a.sh:194-211`、`:316-501` | 增 `internal` 模式（**不删** legacy） | research/01 |
| C5 | New API + PG 部署在 A | `scripts/server-a.sh:1306-1572`、`:3032-3036` | 迁 B（受方案 X 影响） | research/01 + research/05 |
| C6 | ACME HTTP-01 强依赖 TCP/80 | `scripts/server-a.sh:421-501`、`:488`、`:1613` | 由 `tls internal` 替代 | research/01 |
| C7 | 公网伪装站直挂 Caddy 公网 | `scripts/server-a.sh:1654-1695`、`:2083-2700+` | 内网 `portal.mirror.lan` | research/01 |
| C9 | `setup_firewall` 对 `exposure_profile` 零感知 | `scripts/security.sh:576-679` 全文 0 处 grep | 按 profile 分支 | research/01 |
| C10 | vpn-first profile 名不副实 | `scripts/server-a.sh:1712-1789` 仍渲染 `/v1/*` 公网 | vpn-first ⇒ wg0-only | research/01 |
| N1 | Mihomo `allow-lan: true` + `bind: 0.0.0.0`（wg0 内员工拿配置即开放代理） | `configs/mihomo/config.yaml.tpl:34-35`、`scripts/mihomo.sh:523-524` | `bind-address: 10.8.0.1` + `allow-lan: false` | research/03 |
| N2 | `rotate-dest.sh` 切 SNI 不联动 A `client.json`（轮换即握手失败） | `configs/anti-dpi/rotate-dest.sh:266-274` + A `SERVER_B_SNI` 一次性写入 | 加 hook 同步 A | research/03 |

### 4.2 P1 — 应改

| # | 冲突点 | 当前位置 | 修订要求 | 来源 |
|---|---|---|---|---|
| C8 | WG 端口 51820 硬编码 5 个文件 | `vpn.sh:51,1199`、`security.sh:658,727`、`iptables-rules.sh:272`、`iptables-vpn.sh:191`、`firezone-compose.yml` | 30000-65000 随机 + 持久化 | research/02 |
| S1 | SSH 单通道 + 无 admin allowlist | `security.sh:130 _generate_random_port()` | 双通道 60022 + wg0:22 | research/02 |
| S2 | 三套防火墙互抢（UFW/firewalld/iptables） | `security.sh:628`、`:686`；`iptables-rules.sh:178` `ufw disable` | 收敛 nftables | research/02 |
| S3 | fail2ban 双源生成 | `jail.local` + `security.sh:841-899` | 单源 | research/02 |
| S4 | Firezone/Headscale 公网入口残留 | `vpn.sh` VPN_TYPE 分支；`configs/vpn/firezone-compose.yml`、`headscale-config.yaml` | profile 早返回跳过 | research/02 |
| N3 | TPROXY 完全未实现 | `Grep "tproxy-port"` 0 命中（仅战略文档） | 推迟到第二期 | research/03 |
| N4 | Xray client 22 条路由 + 50 行 DNS 与 Mihomo 重复 | `configs/xray/client.json.tpl:145-405`（开发者已注释意识到） | 精简为 1 条路由 + 0 DNS + 1 dokodemo | research/03 |
| N5 | `http-in` 监听 `0.0.0.0:10809`（另一个开放代理面） | `configs/xray/client.json.tpl` | 改 `127.0.0.1` | research/03 |
| U1 | bundle 零打包（6 个零散文件，无 zip/tar） | `user-management.sh:581-743`、`vpn.sh:913-941` | `_generate_client_bundle` ~250 行 | research/04 |
| U2 | WG 模板 `Endpoint :51820` 硬编码 + `AllowedIPs 172.16/24`（非 B_IP） | `vpn.sh:910/920/924` | 端口随机 + B_IP/32 | research/04 |
| B1 | `server-b.sh` 0 处 docker compose（v2 镜像服务空中楼阁） | `Grep "docker compose\|docker-compose" scripts/server-b.sh` 0 命中 | 选型 Verdaccio/registry:2/.../补部署 | research/05 |
| B2 | `ai-gateway-bridge/` 历史快照（README L3 已声明） | 顶层目录 | 归档到 `legacy/` | research/05 |
| B3 | `bifrost-api/` 必须跟 New API 迁 B；Caddyfile-a `/manage/*` 反代目标要改 `127.0.0.1:10800` | `Caddyfile-a.tpl:185-217` `127.0.0.1:8000` | 隧道穿到 B | research/05 |
| B4 | Reality 443 + Caddy 443 冲突；`configs/xray/server.json.tpl` 缺 `fallbacks` 字段 | `server-b.sh:331` 已警告 | 补 fallbacks | research/05 |

### 4.3 P2 — 可缓改

| # | 冲突点 | 来源 |
|---|---|---|
| S5 | Mihomo `external-controller` / dnsmasq 文档未对齐 wg0 | research/01 |
| S6 | bundle 缺 Caddy local CA 根证书分发 | research/01 + research/04 |
| S7 | 6+ 个 ACME 相关变量在 internal 模式下成死代码 | research/01 |
| S8 | `validate_domain_name` 强制 ICP 备案提示，与 mirror.lan 不一致 | research/01 |
| U3 | 离职流程 `disable_user` 不处理 CA（设备永久信任） | research/04 |
| U4 | 移动端 Android 14+ 不信任 user-installed CA，但 `<u>-guide.md:1131` 仍引导装 Shadowrocket | research/04 |
| N6 | 白名单仅 40 条，缺 `raw.githubusercontent.com`、`unpkg.com`、`oaistatic.com`、Docker layer CDN | `configs/whitelist/ai-domains.txt` + research/03 |
| B5 | README B 推荐 1C1G/20G/30Mbps，v2 隐含 8C16G（成本 ×10-20） | research/05 + research/06 |

---

## 5. 推荐落地路径（按 PR 拆分）

> 前置：先开 issue 与 `9877b12` / `04be5ac` / `f90a229` 作者对齐方案 X/Y/Z 选型。

### PR-1：独立安全 bug（不依赖战略决策，可立即合并）

- 修 N1：Mihomo `bind-address: 10.8.0.1` + `allow-lan: false`，关闭 wg0 内开放代理面
- 修 N2：`rotate-dest.sh` 加 hook 同步 A 端 `SERVER_B_SNI`（消除 SNI 切换即握手失败）
- 修 N5：Xray `http-in` 监听改 `127.0.0.1`
- 修 N6：扩 `configs/whitelist/ai-domains.txt`（先扩 20-30 条业内必需），避免上线即断网

### PR-2：低风险加固（任意方案下都适用）

- WG `ListenPort` 30000-65000 随机 + 持久化 `/etc/bifrost.env`（C8）
- nftables 严格模板取代当前 UFW/firewalld/iptables 三套（S2）
- `security.sh` 按 `exposure_profile` 分支控制 80/443 开放（C1/C2/C9）
- fail2ban 单源 + 仅守 SSH（S3）
- journald 限额

### PR-3：vpn-first profile 语义升级

- Caddy 全面支持 `bind 10.8.0.1` 选项（vpn-first 模式下）（C3/C10）
- 新增 `Caddyfile-a-internal.tpl`（保留旧模板为 `Caddyfile-a-public-decoy.tpl.legacy`，加 deprecation banner）
- 增 `tls internal` 模式作为第 4 种 TLS 模式（**不删** domain/cloudflare-origin/ip 三模式）（C4）
- `validate_domain_name` 在 internal 模式下跳过 ICP 提示（S8）
- 弃用变量 deprecation 警告（S7）

### PR-4：用户接入流程 bundle 化

- `user-management.sh` 新增 `_generate_client_bundle`（U1）
- WG `Endpoint` 端口动态 + `AllowedIPs` 改 `10.8.0.0/24,<B_IP>/32`（U2）
- `disable_user` 加 CA rotate 提示（U3）
- 移动端 OS 兼容性文档（U4）
- 新增 `docs/CA-MANAGEMENT.md`（半年一次 root CA rotate 流程）

### PR-5（受方案选型阻塞）：业务迁 B + 镜像服务

- New API + PG 迁 B（C5）
- `ai-gateway-bridge/` 归档（B2）
- `bifrost-api` Caddyfile-a 反代目标改 `127.0.0.1:10800`（B3）
- Reality fallbacks 补字段（B4）
- 镜像服务选型与部署（B1）：
  - npm：Verdaccio
  - docker：`distribution/distribution:2` registry
  - gh：reverse-proxy（不缓存 LFS）
  - hf：先 reverse-proxy，观察流量再决定是否上 LFS 缓存
- README 硬件需求矩阵更新（B5）

### PR-6（受用户决策阻塞）：可选 AmneziaWG L3

- 仅当 PR-2 的 vanilla WG 实测在腾讯云连续 4 周稳定后，**不引入** AmneziaWG
- 若实测被针对，再启用 §1.2 延后项 AmneziaWG L3 + 客户端 awg-quick

---

## 6. 风险与回滚矩阵

| 风险 | 概率 | 影响 | 缓解 | 回滚 |
|---|---|---|---|---|
| WG UDP 高位被腾讯云封 | 中-高（GFW 2026 现状） | A 不可达 | 多端口池 + AmneziaWG L3 备用 | 切方案 X（换香港云）需 1-2 天 |
| 腾讯云"翻墙业务"风控封号 | 中（RFA 2026-04 报道） | 整机封停 | 提前迁香港 / 避免高位 UDP 单一画像 | 不可回滚（封号无救） |
| 删除 `9877b12` IP HTTPS 代码 | — | 与近期 commit 公开矛盾 | **不删，保留为 legacy 模式 + deprecation** | 留代码不动 |
| 现网有备案用户被迫切 vpn-first | 低 | 公网 `/v1/*` 入口消失 | 保留 `public-managed` profile + 强警示 | profile 切回即可 |
| 强制根 CA 法务拒绝 | 中 | 企业合规阻塞 | 仅 VPN 管理面用 internal CA，业务面走方案 X 公开证书 | 不分发 root CA |
| Caddy local CA 私钥泄漏 | 低 | 内网 PKI 失效 | 权限 700 + 加密备份 + 半年 rotate | rotate root CA |
| Mihomo 默认 REJECT 上线即断网 | **高**（白名单仅 40 条） | 全员不可用 | **PR-1 先扩白名单**；灰度 reject | 切 `DIRECT` 默认 |
| B 端 8C16G 升级成本失控 | 中 | 客户拒绝部署 | 方案 X 把镜像放 A 香港 | 不升级 B |
| AmneziaWG fork 工具链供应链 | 中（长期） | 客户端碎片 + DKMS 维护 | **不引入**（默认 vanilla WG） | 不引入即无回滚需要 |

**关键原则**：v2 §13 单向门式改造（部署后回滚 ≈ 重装）不可接受。本规划强制要求所有 PR 提供回滚标志（`BIFROST_EXPOSURE_PROFILE` 切换即可），不留单向门。

---

## 7. 开放问题（必须用户决策才能继续）

| Q# | 问题 | 影响 |
|---|---|---|
| Q1 | **接受方案 X（A 改香港云）吗**？接受则 PR-3/5/6 大部分工作不需要 | 决定整体方向 |
| Q2 | **`9877b12` IP HTTPS 代码去留**？保留为 legacy / 删除 / 还原为主路径 | 决定 PR-3 边界 |
| Q3 | 强制 VPN-only 对非技术员工（PM/财务/HR）的覆盖率怎么定？ | 决定 PR-4 复杂度 |
| Q4 | 接受 README "一键部署、零运维" 定位被改成"企业内网零信任 PKI 改造方案" 吗？ | 决定产品文档重写量 |
| Q5 | B 端硬件升级到 8C16G 月成本 $80-160 客户能接受吗？ | 决定 PR-5 启动条件 |
| Q6 | vanilla WG 在腾讯云的 4 周实测预算谁出？ | 决定 PR-6 启动条件 |
| Q7 | 现网已用 `domain` / `cloudflare-origin` / `ip` 模式的生产用户怎么迁移？ | 决定 deprecation 节奏 |

---

## 8. 配置变量重命名建议

| 变量 | 现状 | 修订后 | 备注 |
|---|---|---|---|
| `BIFROST_SERVER_A_TLS_MODE` | `domain`/`cloudflare-origin`/`ip` | `internal`（默认）/ `cloudflare-origin` / `legacy-domain` / `legacy-ip` | legacy 加 deprecation 提示 |
| `BIFROST_EXPOSURE_PROFILE` | `vpn-first`/`public-managed`/`lab` | 同上但升级语义：vpn-first ⇒ Caddy 仅 wg0、security.sh 不开 80/443 | research/01 §3 已有抽象，仅需升级 |
| `BIFROST_WG_PORT` | 不存在 | 默认 `shuf 30000-65000`，持久化 `/etc/bifrost.env` | 新增 |
| `BIFROST_WG_OBFUSCATION` | 不存在 | 默认 `none`，可选 `amneziawg`（PR-6） | 新增 |
| `BIFROST_ADMIN_SSH_PORT` | 隐含 22 / 安装时随机 | 默认 60022 | 新增 |
| `BIFROST_ADMIN_SSH_ALLOWLIST` | 不存在 | CIDR list，配 nftables `set` | 新增 |
| `BIFROST_CERTBOT_INSTALL_METHOD` | 存在 | 仅 legacy-ip 模式才有效 + deprecation | 收窄 |
| `BIFROST_LETSENCRYPT_STAGING` | 存在 | 仅 legacy 模式 + deprecation | 收窄 |
| `BIFROST_ACME_EMAIL` | 存在 | 仅 legacy 模式 + deprecation | 收窄 |

---

## 9. 与 v2 文档自身的批判性反馈

v2 文档应补充的内容（建议作者修订）：

1. **方案 X/Y/Z 对比章节**（v2 完全沉默）
2. **`9877b12` 去留显式回答**（v2 §13.1 仅删 ACME，未提 460 行 IP HTTPS 函数）
3. **B 端硬件升级成本透明化**（v2 §15 隐含 8C16G 但无成本论证）
4. **"伪装站重定义" 坦白**：v2 模式下"抗主动探测"被放弃，不是"伪装能力延续"
5. **WG UDP 自相矛盾消除**：§2.1 "UDP 监管最弱" vs §14 "高位 UDP 被画像"，需统一口径
6. **回滚预案明确化**：当前 §14 "腾讯云风控规则升级→换其他云厂商" 等同重装
7. **`tls internal` 在 Windows 域控/BYOD 无 admin 场景的可行性评估**
8. **§18.6 "国内云强制 private-internal" 改为"国内云 + 未备案"双条件**（避免误伤有备案合法用例）

---

## 10. 下一步

1. **此规划文档放进 PR 描述**，邀请 `9877b12` / `04be5ac` / `f90a229` 提交者评审
2. 用户决策 §7 七个开放问题（特别是 Q1 方案 X）
3. 基于决策结果：
   - 若选方案 X → 主线 PR-1/PR-2 + 简化 PR-3（无需 Caddy 全内迁）+ 跳过 PR-5 大部分
   - 若坚持国内云 → 全六 PR + 强 deprecation 路径
4. 创建子任务：`05-19-mihomo-bind-fix`（PR-1 单独可立刻动手）、`05-19-rotate-dest-sni-sync`（PR-1）、`05-19-wg-port-randomize`（PR-2）

---

> 规划文档：v1.0 · 2026-05-19 · ZRainbow
> 上游战略：`prompts/server-a-hardening-strategy.md` v2.0
> 审查证据：`prompts/0519/research/01-06`
> 审查方法：6 个并行 agent + WebFetch/WebSearch 实证 + git show + Grep/Read 代码扫描
> Trellis 任务：`.trellis/tasks/05-19-server-a-hardening-v2/`
