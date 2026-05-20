# 代理栈现状 vs v2 审查

> 审查范围：Mihomo + Xray client + anti-dpi 三件套与白名单/DNS/分流脚本，对照 `prompts/server-a-hardening-strategy.md` §6/§7/§11 的 v2 设计取证。
> 取证规则：所有指控均给出 `file:line`。下文 `configs/mihomo/config.yaml.tpl` 与 `scripts/mihomo.sh` 的双引用，表示模板与脚本内嵌的 fallback 同步偏离 v2。

---

## 1. Mihomo 监听与管理面

**现状（取证）**：

- `configs/mihomo/config.yaml.tpl:34-35` `allow-lan: true` + `bind-address: "*"`；同样代码在 `scripts/mihomo.sh:523-524` 的兜底生成函数 `_mihomo_generate_config_direct` 内被重复硬编码（写死 `bind-address: "*"`）。
- `configs/mihomo/config.yaml.tpl:60` `external-controller: 127.0.0.1:{{MIHOMO_API_PORT}}`；`scripts/mihomo.sh:545` 同值。`MIHOMO_API_PORT=9090`（`scripts/mihomo.sh:67`），但 v2 §6 要求 `external-controller: '10.8.0.1:9090'` 绑 wg0。
- `mixed-port: 7890` / `socks-port: 7891`（`scripts/mihomo.sh:65-66`、`configs/mihomo/config.yaml.tpl:32-33`），DNS `listen: 0.0.0.0:1053`（`configs/mihomo/config.yaml.tpl:78`）。
- **完全没有 `tproxy-port`**：`Grep "tproxy-port"` 仅命中 `prompts/server-a-hardening-strategy.md:525`，源代码 0 命中。

**v2 差距**：

| v2 要求 | 当前实现 | 差距 |
| --- | --- | --- |
| `bind-address: '10.8.0.1'` 仅 wg0 | `"*"` 任意接口 | **严重**：DNS:1053、mixed:7890、socks:7891 全部 0.0.0.0；公网若漏防火墙即开放代理 |
| `external-controller: '10.8.0.1:9090'` | `127.0.0.1:9090` | 表面安全（loopback），但 v2 设计意图是让 wg0 内员工/工具能访问 dashboard，当前 SSH 隧道或 wg 客户端均无法直连 |
| `tproxy-port: 7895` + `mixed-port: 0` | `mixed-port: 7890` 且无 TPROXY | **架构差异**：当前是显式 HTTP_PROXY 模型（Docker 设 env），v2 是 TPROXY+nftables 透明劫持 |
| `allow-lan: false` | `true` | 与 bind-address "\*" 配合形成开放代理面 |

**默认规则审查**（`configs/mihomo/config.yaml.tpl:244-274`）：

```yaml
- IP-CIDR 私网/127.0/loopback → DIRECT          # L246-254
- GEOSITE,category-ads-all → REJECT             # L257
- RULE-SET,streaming-block → REJECT             # L260
- RULE-SET,ai-domains → AI-Proxy                # L263
- GEOSITE,cn / GEOIP,CN → DIRECT                # L266-267
- GEOSITE/GEOIP,private → DIRECT                # L270-271
- MATCH,REJECT                                  # L274
```

**当前已经是 `MATCH,REJECT` 白名单模式**——这与 v2 §6:613 一致，不是新增需求。这一点项目做得很好，不存在"v2 引入默认拒绝破坏旧逻辑"的问题。**但是**白名单内容（见 §5）严重不足以支撑 v2 的镜像 + 员工生产场景。

---

## 2. DNS 链路

**现状（取证）**：

- **完全没有 dnsmasq**：`Grep "dnsmasq"` 仅命中 `prompts/server-a-hardening-strategy.md`，源代码 0 命中。
- Mihomo 自带 DNS：`configs/mihomo/config.yaml.tpl:77-131`，`listen: 0.0.0.0:1053`，`enhanced-mode: fake-ip`，`fake-ip-range: 198.18.0.1/16`。
- `nameserver-policy`（L123-131）按 `geosite:cn,private` → 国内 DoH（阿里/腾讯），`geosite:geolocation-!cn` → 海外 DoH（CF/Google）。
- **没有 `*.mirror.lan` 解析**：`Grep "mirror\.lan"` 0 命中源代码。
- Xray client 也内嵌一份 DNS 配置（`configs/xray/client.json.tpl:7-55`），按域名分配 DoH，与 Mihomo DNS 重复且没协作机制。

**v2 差距**：

| v2 要求 | 当前实现 | 偏差 |
| --- | --- | --- |
| dnsmasq 占 53，前置入口 | 不存在 | **缺失**：员工 DNS 无统一入口 |
| dnsmasq 处理 `*.mirror.lan` → 10.8.0.1 | 无 | **缺失**：Caddy 反代依赖此 DNS 链路才能形成 `npm.mirror.lan` 等命名 |
| Mihomo DNS `listen: '10.8.0.1:5353'`（被 dnsmasq 转发） | `0.0.0.0:1053` | 端口号、监听面、协作模式三处都不同 |
| dnsmasq `server=10.8.0.1#5353` 兜底转发 | 无 | 双层架构整体缺失 |

**判定**：mirror.lan 命名+dnsmasq 双层 DNS 是 v2 **新增** 设施。项目当前是单层 Mihomo fake-ip。落地要求新增 `scripts/dns.sh`（或纳入 `server-a.sh`）部署 dnsmasq，并将 Mihomo `listen` 改 `10.8.0.1:5353`。fake-ip 与 dnsmasq DOMAIN 解析的协作要小心：mirror.lan 必须走真实解析（不走 fake-ip），Mihomo 需把 `*.mirror.lan` 加入 `fake-ip-filter`（当前 L85-110 没有 mirror.lan）。

---

## 3. Xray client 精简

**现状（取证）**：

- `configs/xray/client.json.tpl:56-95` 双 inbound：socks-in（127.0.0.1:10808）+ http-in（**0.0.0.0:10809**）。
- `configs/xray/client.json.tpl:145-405` 内嵌一套**完整**路由：广告 REJECT、streaming REJECT、AI services 显式 proxy、CN/private DIRECT、`port "0-65535"` 兜底 block。这与 Mihomo `config.yaml.tpl:244-274` 的路由规则**几乎完全重复**。
- DNS 也在 Xray 里再做一遍（`client.json.tpl:7-55`），按域名分配 DoH。
- **没有 dokodemo-door inbound**：`Grep "dokodemo"` 仅命中 `server.json.tpl:81`（Server B 的 api-in）和 strategy 文档。

**v2 §7 要求**：

```json
inbounds: [{ tag:"from-mihomo", listen:"127.0.0.1", port:10800, protocol:"dokodemo-door", sniffing:{...} }]
outbounds: [{ tag:"reality-to-b", VLESS+Reality+xtls-rprx-vision, mux 8 }]
routing: 一条规则 { inboundTag:["from-mihomo"], outboundTag:"reality-to-b" }
```

**简化幅度**：

| 维度 | 现状 | v2 | 删除量 |
| --- | --- | --- | --- |
| inbound 数量 | 2（socks+http）| 1（dokodemo）| -1 |
| inbound 监听面 | http-in 是 `0.0.0.0` | `127.0.0.1` only | 收敛公开面 |
| DNS 段 | 50 行（`client.json.tpl:7-55`）| 删除 | -50 行 |
| routing 规则 | 22 条 | 1 条 | -21 条 |
| outbound 数 | 3（proxy/direct/block）| 1（reality-to-b）| -2 |
| 协议指纹 | 缺 mux 配置（被 anti-dpi 后期注入）| 模板内置 mux | 合并 |

注意 `client.json.tpl:153` 有一条注释：*"Trust Mihomo routing: all traffic from SOCKS5 inbound goes to proxy"*——说明开发者已经意识到"Mihomo 决策、Xray 透传"的设计意图，但代码上**没有删除重复路由**，只是在最前面加了一条 socks-in→proxy。这是技术债。

**Reality outbound 当前 dest 来源**：

- `client.json.tpl:115-126` 的 `serverName/publicKey/shortId` 由 `template_render` 填入，来源是 `/root/server-b-connection.conf`（`scripts/mihomo.sh:71` 的 `_MIHOMO_SERVER_B_CONF`），即 Server A 部署时人工收集 Server B 信息。
- dest-pool 的轮换**只发生在 Server B 端的 `inbounds[].streamSettings.realitySettings.dest/serverNames`**（`scripts/anti-dpi.sh:479-486`、`rotate-dest.sh:266-274`），**不动 Server A client 配置**。
- 当 B 上的 dest 轮换后，A 上的 `SERVER_B_SNI` 不会自动同步——这是个**潜在 BUG**：rotate-dest.sh 重启 B 的 Xray 后，A 客户端依然用旧 SNI 发起 Reality 握手，会因 serverNames mismatch 直接被 reject。本审查范围外但要标记。

---

## 4. anti-dpi 作用域转移

**现状（取证）**：

- `scripts/anti-dpi.sh:1077-1171` 的 `deploy_anti_dpi` 含 6 步：dest pool、初始 rotation、uTLS 指纹、mux+padding、active probe defense、cron 轮换。
- `scripts/anti-dpi.sh:733-814` 的 `setup_active_probe_defense` 显式判断"无 Reality inbound 则跳过"（L751-755）——意味着 A 上跑 deploy_anti_dpi 时这一步会自然跳过。
- 但其余 5 步**会在 A 上误跑**：
  - dest pool 写到 `/opt/bifrost/dest-pool.txt`（A 上根本用不到）
  - rotate_dest（L403-512）尝试 `jq '.inbounds[] | select(.streamSettings.security == "reality") | .streamSettings.realitySettings'`——A 的 client.json 没有 reality inbound，jq 结果为空，但 mv-f 仍会写一份"未变化"的 config 回去
  - 还会通过 `setup_dest_rotation_cron`（L902）在 A 上装一个每周日 03:17 的 cron，跑 `/opt/bifrost/rotate-dest.sh`，**这个 cron 在 A 上没意义**
- `scripts/server-a.sh` Grep 结果：**0 处调用 anti-dpi**（确认）。但用户可手动 `./install.sh --anti-dpi` 在 A 上启动（`install.sh:602-605`），脚本不会拒绝。
- `scripts/server-b.sh:2322-2326` 在 server-b 流程内调用 deploy_anti_dpi——这是预期路径。

**v2 §11 重申**：Reality 服务端只在 B，A 仅作 client。

**判定**：

1. 当前架构上 anti-dpi 主流程在 B 跑，A 不主动调用，**功能上已对齐 v2**。
2. **但** `install.sh --anti-dpi` 入口和 `mihomo.sh` 互不知情，存在误操作风险（管理员在 A 跑了一次 --anti-dpi，A 上凭空出现 dest-pool.txt + rotate-dest.sh cron）。
3. uTLS fingerprint 配置（`anti-dpi.sh:524-602`）是 client 侧概念，理论上 A 应该跑这一步给 client.json 注入 `streamSettings.realitySettings.fingerprint`——但 `client.json.tpl:120` 已经把 `fingerprint: "chrome"` 硬编码进模板了，所以 A 上跑反而是冗余。
4. **建议**：`install.sh --anti-dpi` 加 Server B 角色守门（检测 `/usr/local/etc/xray/config.json` 是否含 reality inbound），或在 `deploy_anti_dpi` 入口先 guard，A 上仅跑"setup_utls_fingerprint client 模式"+"mux 注入"两步。

dest-pool.txt（`configs/anti-dpi/dest-pool.txt:23-46`）当前 13 个 dest：dl.google.com、cloud.google.com、www.microsoft.com、learn.microsoft.com、www.apple.com、www.mozilla.org 等。这是给 B 服务端 Reality serverNames 用的，与 v2 §11 一致，**无需迁移**。

---

## 5. AI 域名白名单 vs 默认 REJECT

**现状（取证）**：

- `configs/whitelist/ai-domains.txt` 共 121 行，但去掉注释和空行后实际域名约 **40 条**：
  - Anthropic 5 条（api/claude/console/statsig/sentry）
  - OpenAI 5 条
  - Google Gemini 5 条
  - DeepSeek/Mistral/Groq/Cohere 各 1-2 条
  - GitHub/Copilot 6 条
  - HuggingFace 3 条
  - Together/Perplexity 各 1-2 条
  - 包注册表 5 条（npmjs.org/pypi.org/files.pythonhosted/crates.io/static.crates.io）
  - Docker 4 条（registry.docker.com/docker.io/registry-1.docker.io/production.cloudflare.docker.com/ghcr.io）
- `configs/mihomo/ruleset/ai-domains.yaml` 共 35 个规则项（`Read` 全文），用 DOMAIN-SUFFIX 聚合到 ~20 个根域。
- 当前 Mihomo `MATCH,REJECT` 兜底已经生效（`config.yaml.tpl:274`）。

**v2 §6 + §14 引申**：

- `RULE-SET,ai,PROXY` 走代理
- `RULE-SET,mirror,PROXY`（**新增 mirror-domains 规则集**，注意不是 mirror.lan）
- `DOMAIN-SUFFIX,mirror.lan,DIRECT`（让 Caddy 反代生效，不出 A）
- `MATCH,REJECT` 兜底

**白名单覆盖率审查**：

| v2 场景 | 当前白名单是否覆盖 | 缺漏 |
| --- | --- | --- |
| Claude 全链路 | 部分 | 缺 `statsig.com`（非 anthropic 子域）、`segment.io`、`amplitude.com` 等 telemetry |
| OpenAI 全链路 | 部分 | 缺 `oaistatic.com`（ChatGPT 前端 CDN）、`oaiusercontent.com` |
| Google Gemini | 完整 | OK |
| npm 元数据 + tarball | 仅 registry | 缺 `npmjs.com`（前端）、`unpkg.com`、`jsdelivr.net` |
| pip 完整链路 | 仅 pypi.org | 缺 `files.pythonhosted.org`✓ 已有 |
| Docker Hub 镜像层 | 部分 | 缺 `cloudfront.net`（layer CDN）、`auth.docker.io` |
| HuggingFace LFS 大文件 | 部分 | 缺 `huggingface.co/api/`*、cdn-lfs URL；`cdn-lfs.huggingface.co` 已有 |
| GitHub raw / releases | 部分 | github.com 已有；缺 `raw.githubusercontent.com`、`objects.githubusercontent.com`、`codeload.github.com` |
| 内网 mirror.lan | **完全缺失** | 还没建概念 |

**员工申请新域名的流程**：项目无任何 portal/UI 自助流程。`scripts/whitelist.sh` 是 CLI 操作工具（`scripts/whitelist.sh:14-21` add/remove/test/list），需要 root + SSH 才能操作。v2 §14 提到的"portal 自助申请"在当前架构下**不存在前端入口**。落地 v2 必须新增 portal API/HTML。

**默认拒绝灰度风险**：当前 `MATCH,REJECT` 已生效，理论上风险已显化。但项目实际上线时大概率没有真员工跑业务，所以"灰度"是部署后才会暴露的问题。建议 v2 启用时配合 `proxy-group: PROXY` 的中间过渡（先让未识别流量记录 + 通过，再切 REJECT）。

---

## 6. 镜像服务路由

**Grep 真实数据**：

```
$ Grep "npm\.mirror|docker\.mirror|gh\.mirror|hf\.mirror|api\.mirror|portal\.mirror"
Found 1 file: prompts/server-a-hardening-strategy.md
```

源代码 **0 命中**。意味着：

- 当前 Caddy/Mihomo/Xray/whitelist 配置里**没有任何 mirror.lan 子域**。
- 也没有 npm/docker/gh/hf 镜像服务的 docker-compose（项目当前镜像是直连 npmjs.org/docker.io 经隧道走 B，没"本地镜像"概念）。
- `DOMAIN-SUFFIX,mirror.lan,DIRECT` 这条 v2 关键规则**不存在**。

**判定**：整套"内网镜像服务"在 v2 是**全新功能**，需要：

1. 在 B 上跑 verdaccio（npm）、docker registry（distribution）、hf 镜像缓存等。
2. A 上 Caddy 配 `*.mirror.lan` vhost 反代 → Xray dokodemo → B → 镜像服务（v2 §3.1）。
3. Mihomo 加 `DOMAIN-SUFFIX,mirror.lan,DIRECT` + `mirror-domains` 规则集（指向 npmjs/dockerhub/gh/hf 等源站，走 PROXY）。
4. dnsmasq 加 `address=/.mirror.lan/10.8.0.1`。

工作量评估：B 上每个镜像服务 ~50 行 docker-compose + Caddy 反代；A 上 Caddy `*.mirror.lan` block 一份；Mihomo+dnsmasq 各 5 行。属于中等增量，但**前置依赖**是 §1（Mihomo 绑 wg0）和 §2（dnsmasq）必须先落。

---

## 7. 风险

1. **默认 REJECT 上线即断网风险（中）**：当前 `MATCH,REJECT` 已生效，但白名单只覆盖 AI 核心域。员工要装 VS Code 扩展、跑前端构建（webpack 拉 unpkg）、看 Stack Overflow——全部被 REJECT。v2 上线前必须把白名单扩 3-5 倍并设"申请通道"，否则第 2 天报障爆炸。**灰度策略**：临时把 `MATCH` 从 REJECT 改 PROXY 跑一周收集 access.log，把高频域追加白名单后再切回 REJECT。

2. **TPROXY 与 nftables 冲突点（高）**：v2 §5:497-504 要求 nftables `forward` chain + `prerouting_mangle` chain 配合 Mihomo TPROXY。当前项目用的是显式 HTTP_PROXY 模型（Docker env 注入），**完全没有 TPROXY 路径**。切到 v2 需要：
   - Mihomo 配 `tproxy-port: 7895` 并启动时 PostUp 注入 nftables 规则
   - 但 `scripts/iptables-rules.sh`（split-tunnel.sh:113 引用）当前是 iptables 不是 nftables
   - **混用 iptables-legacy + nftables 会出现规则相互不可见**，Debian 12 默认 nftables backend 但 iptables-nft 兼容层有边界情况
   - 建议彻底切到 nftables 单栈，全项目移除 iptables 命令

3. **Mihomo `bind-address: "*"` + `allow-lan: true` 的开放代理面（高）**：即使 nftables drop 公网，wg0 内任何客户端都能用 mixed-port:7890 当 HTTP 代理任意访问内网/外网。员工被钓鱼后 IP 泄漏，攻击者拿到 WG conf 即可经此代理打内网。v2 `bind-address: '10.8.0.1'` + `allow-lan: false` 闭这个口。

4. **DNS 缓存毒化风险（中）**：fake-ip 198.18.0.1/16 与 Caddy 内网 10.8.0.1 互不冲突，但若客户端配错 DNS 直查国内 DNS，`*.mirror.lan` 会得到 NXDOMAIN 然后 Mihomo 拿不到 sniffer 数据。v2 必须强制 WG 客户端 `DNS = 10.8.0.1`，不允许覆盖。

5. **rotate-dest 与 A client SNI 失同步（高，已在 §3 标注）**：B 上 dest 轮换后 A 上 `SERVER_B_SNI` 未联动，握手立即失败。需要在 `rotate-dest.sh` 末尾推送新 SNI 到 A，或 A 上定期 pull `/root/server-b-connection.conf`。这是当前**就存在**的 bug，v2 切换前必须先修。

6. **whitelist.sh 没有热生效（低）**：`scripts/whitelist.sh add` 只改 `ai-domains.txt`，需要手动 rerun `generate_mihomo_rulesets`（`scripts/mihomo.sh:717`） + `systemctl reload mihomo`，否则不生效。v2 加 portal 申请通道前要先把这条链路自动化。
