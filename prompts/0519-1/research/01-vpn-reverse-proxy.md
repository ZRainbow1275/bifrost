# Research: VPN Reverse Proxy for Server B Private Distribution

- **Query**: VPN 内部部署 Verdaccio + Caddy + git mirror，Server A (公网) 反代到 Server B (内网, WireGuard)
- **Scope**: External (primary sources fetched live)
- **Date**: 2026-05-19
- **Architecture target**:
  - Server B (内网，真正服务端) — Verdaccio :4873、static :80/:443、git mirror，不暴露公网 IP
  - Server A (公网 VPS) — VPN hub + 反向代理入口 (`uuhfn.cloud`)
  - 白名单 VPS — 通过 WireGuard 与 B 直连
  - 团队从 `uuhfn.cloud` 走 A → wg → B

---

## Topic 1 — WireGuard hub-and-spoke 下做反向代理转发

### 1.1 拓扑选型

引用 Pro Custodibus《Primary WireGuard Topologies》（https://www.procustodibus.com/blog/2020/10/wireguard-topologies/）：

> "The hub and spoke topology is similar to a virtual VPN-style network … two endpoints running WireGuard are connected through a third host, also running WireGuard. This third host operates as a router among the WireGuard endpoints connected to it … forwarding the packets it receives though a WireGuard tunnel from one endpoint on to a second endpoint through a different WireGuard tunnel."
>
> "Hub and Spoke topology is a good way to enable remote access management among a diverse set of remote endpoints … with routing rules, access control, and traffic inspection all centralized in one place (the hub)."

**关键事实**（来自 https://www.wireguard.com/quickstart/）：

- `AllowedIPs` 同时充当 **路由表 + ACL**（cryptokey routing），错配会导致包被丢弃或走错隧道
- `PersistentKeepalive = 25` 是穿透 NAT/状态防火墙的推荐值，hub 后面的 spoke 必须配
- WireGuard 默认 **不会** 在 peer 之间转发包，需要在 hub 上 `sysctl net.ipv4.ip_forward=1` 才能形成 hub-and-spoke

### 1.2 三种反代方案

| 方案 | 做法 | Pros | Cons |
|---|---|---|---|
| **A. Caddy L7 在 A 上 reverse_proxy 到 B 的 wg0 IP** | A 跑 Caddy（HTTP server）→ `reverse_proxy 10.13.13.2:4873`，wg0 子网走加密隧道 | 配置最简；HTTPS 证书由 A 统一管理；可注入 `X-Forwarded-*` 头给 Verdaccio | TLS 在 A 终止，A 私钥泄漏=整站沦陷；A 看得到明文 npm token |
| **B. Caddy L4 (caddy-l4) 在 A 上做 SNI 透传** | A 装 [caddy-l4](https://github.com/mholt/caddy-l4)，按 SNI 路由原始 TCP 到 B:443 | 私钥放 B；A 看不到明文；E2E 加密延伸到 B | 失去 L7 头注入；A 不能做缓存/限流；Verdaccio 必须自己有 cert |
| **C. WireGuard 全员入网，A 只做 DNS/路由** | 客户端也接 wg，直接访问 B | 真正的 E2E；A 故障不影响内部访问 | 团队所有人要装 wg；公网无法访问；不符合"团队从域名访问"需求 |

### 1.3 Caddy 反代的具体配置（方案 A，最契合需求）

Verdaccio 反代必须设置的头（来自 https://verdaccio.org/docs/reverse-proxy）：

```
proxy_set_header X-Real-IP $remote_addr;
proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
proxy_set_header Host $host;
proxy_set_header X-Forwarded-Proto $scheme;
```

Caddy 等价（Caddyfile）：

```caddyfile
uuhfn.cloud {
    # Caddy 自动注入 X-Forwarded-For / X-Forwarded-Proto / Host
    # Verdaccio 在 config.yaml 里要设置 url_prefix: "https://uuhfn.cloud" 和 listen: 0.0.0.0:4873
    reverse_proxy 10.13.13.2:4873 {
        header_up Host {host}
        header_up X-Real-IP {remote_host}
        # 大包：tar 上传/下载
        flush_interval -1
    }
}
```

引自 Caddy 官方 https://caddyserver.com/docs/caddyfile/directives/reverse_proxy：

> "Static upstream addresses can take the form of a URL that contains only scheme and host/port, or a conventional Caddy network address."

注意 Caddy reverse_proxy 不允许 upstream 含 path，路径改写必须用 `rewrite` 或 `handle_path`。

### 1.4 我们的取舍建议

**采用方案 A（Caddy L7 反代到 wg0 IP）作为 MVP**，理由：

1. 需求明确"团队从 A 域名访问" → 必须有 L7 网关
2. Verdaccio 需要 `X-Forwarded-Proto` 才能生成正确的 tarball URL（否则下载链接会变成 `http://localhost:4873/...`）
3. 后续若担心 A 私钥安全，再切换到方案 B（L4 SNI 透传）
4. Server B 上 Verdaccio **必须** `listen: 0.0.0.0:4873` 而不是 `127.0.0.1`，否则 wg0 上的 A 连不上；同时靠 nftables 锁死端口（见 Topic 2）

---

## Topic 2 — nftables 严格白名单（B 的 4873/80/443 只允许 wg + 白名单 VPS）

### 2.1 nftables 核心语法（来自 https://wiki.nftables.org/）

引用官方 wiki：

- `policy drop` 是终极兜底：base chain 默认丢弃所有未明确 accept 的包
- `iifname "wg0"` 按入接口匹配（最稳，wg0 是 B 自己控制的 interface）
- `ip saddr <CIDR>` 按源 IP 匹配
- `tcp dport vmap { 4873: accept, 80: accept, 443: accept }` vmap 简洁表达多端口

### 2.2 三种白名单粒度

| 方案 | 做法 | Pros | Cons |
|---|---|---|---|
| **接口白名单** | `iifname "wg0" accept` + INPUT 默认 drop | 配置最简；只要进了 wg 就放行 | 任何 wg peer 都能访问全部内部端口，权限粒度粗 |
| **IP 白名单（wg 子网 + 白名单 VPS 公网 IP）** | `ip saddr { 10.13.13.0/24, 1.2.3.4, 5.6.7.8 } tcp dport {4873,80,443} accept` | 双重保险：wg 子网 + 几个固定公网 IP；wg 挂了也能从应急 IP 进 | 白名单 VPS 是公网 IP，被劫持/迁移时要改规则 |
| **接口+IP 双层** | wg0 接口全放 + 公网接口仅放白名单 IP 到 4873/80/443 | 最严格；公网完全静默；wg 内部灵活 | 配置最复杂；调试要看 `nft trace` |

### 2.3 推荐 nftables 配置（方案 C - 双层）

```nft
table inet filter {
    set vpn_whitelist {
        type ipv4_addr
        elements = { 1.2.3.4, 5.6.7.8 }    # 白名单 VPS 公网 IP
    }

    chain input {
        type filter hook input priority 0; policy drop;

        # 1. 本机/已建立连接
        iif lo accept
        ct state established,related accept
        ct state invalid drop

        # 2. ICMP (诊断必备)
        ip protocol icmp icmp type { echo-request } limit rate 10/second accept
        ip6 nexthdr icmpv6 accept

        # 3. SSH (从白名单 VPS 或 wg)
        tcp dport 22 ip saddr @vpn_whitelist accept
        tcp dport 22 iifname "wg0" accept

        # 4. WireGuard 端口（让 spoke 能进来）
        udp dport 51820 accept

        # 5. 业务端口：只接受来自 wg0 的流量
        iifname "wg0" tcp dport { 4873, 80, 443 } accept

        # 6. 兜底：drop（policy 已经是 drop，写出来更醒目）
        log prefix "nft-drop: " limit rate 5/minute
    }

    chain forward {
        type filter hook forward priority 0; policy drop;
        # B 不做 hub，不转发
    }

    chain output {
        type filter hook output priority 0; policy accept;
    }
}
```

引用 nftables 官方文档要点：

> "policy is the default verdict statement to control the flow in the base chain. Possible values are: accept (default) and drop. Warning: Setting the policy to drop discards all packets that have not been accepted by the ruleset."

### 2.4 我们的取舍建议

**采用方案 C（双层）**：

1. 业务端口 4873/80/443 **只走 wg0**，公网完全静默 → 即使 nmap 也扫不到
2. SSH 双通道：wg + 白名单公网 IP（防止 wg 挂掉时无法救援）
3. 用 `set` 管理白名单 → `nft add element inet filter vpn_whitelist { 新IP }` 不需要 reload
4. 必须用 `inet` 家族（同时处理 v4/v6）；只用 `ip` 表会漏掉 IPv6 流量
5. 持久化：Debian/Ubuntu 写到 `/etc/nftables.conf` + `systemctl enable nftables`

**陷阱提醒**：

- `policy drop` 在 SSH 连接中加载规则会断线，**第一次必须用 `at now + 5 min` 备份回滚**
- WireGuard 监听 UDP，不要写成 `tcp dport 51820`
- Docker 会偷偷往 nftables 塞规则到 `nat` 表，业务端口最好别用 docker-published；用 host network 或直接监听 wg0 IP

---

## Topic 3 — Caddy SNI 透传 vs L7 终止：私钥放哪台

### 3.1 两种模式对比

引用 caddy-l4 项目说明（https://github.com/mholt/caddy-l4）：

> "If connection is TLS, terminate TLS then proxy all bytes to :5000."
> "If connection is TLS, proxy to :443 without terminating; if HTTP, proxy to :80; if SSH, proxy to :22."
> "If the HTTP Host is example.com or the TLS ServerName is example.com, then proxy to 192.168.0.4."

caddy-l4 的 SNI 透传配置（来自 `docs/examples/tls_sni_dynamic_upstreams.md`）：

```caddyfile
{
    layer4 {
        :443 {
            @tls-any tls
            route @tls-any {
                proxy {l4.tls.server_name}:443
            }
        }
    }
}
```

注意：**这里没有 `terminate` 子句，所以 TLS 加密的字节流被原封不动转发到上游**。

| 维度 | L7 终止（Caddy reverse_proxy） | L4 SNI 透传（caddy-l4） |
|---|---|---|
| 私钥位置 | **Server A** (公网) | **Server B** (内网) |
| TLS 解密点 | A | B |
| 明文可见 | A 看到全部 HTTP（含 npm token, basic auth） | A 只看到 SNI 字段，其他是密文 |
| HTTP 头注入 | ✅ Caddy 自动加 `X-Forwarded-For/Proto` | ❌ 上游收不到任何 L7 hint |
| 缓存/限流 | ✅ Caddy 全部支持 | ❌ L4 只能做 conn-level 限流 |
| 证书自动化 | ✅ A 上 ACME HTTP-01/TLS-ALPN-01 自动 | ⚠️ B 必须能完成 ACME（B 不在公网，只能用 DNS-01） |
| WebSocket / HTTP/2 | ✅ 原生 | ✅ 透传 |
| HTTP/3 (QUIC) | 部分（Caddy 支持） | ❌ caddy-l4 README 明确"TCP-only" |
| 故障半径 | A 挂 = 全挂 | A 挂 = 全挂（一样） |
| **运维复杂度** | **低** | 中（要 xcaddy 编译 + DNS-01） |

### 3.2 Cloudflare Origin CA 私钥安全考量

引用 Cloudflare 官方（https://developers.cloudflare.com/ssl/origin-configuration/origin-ca/index.md）：

> "If your origin only receives traffic from proxied records, use Cloudflare origin CA certificates to encrypt traffic between Cloudflare and your origin web server."
> "Site visitors may see untrusted certificate errors if you pause Cloudflare or disable proxying on subdomains that use Cloudflare origin CA certificates. **These certificates only encrypt traffic between Cloudflare and your origin server, not traffic from client browsers to your origin.**"
> "For security reasons, you cannot see the Private Key after you exit this screen."

**对本架构的关键含义**：

1. **Origin CA 私钥不被任何浏览器信任** —— 它只在 Cloudflare 边缘 ↔ origin 之间使用
2. 团队成员的 `npm install` 客户端 **不会** 走 Cloudflare（除非用 `https://uuhfn.cloud` 而且 DNS 是 proxied=橙云）。如果走 Cloudflare 代理：
   - 客户端 ↔ Cloudflare: 用 Cloudflare 公共证书（浏览器信任）
   - Cloudflare ↔ A: 用 Origin CA 证书
   - A ↔ B: 取决于 L7/L4 选择
3. 如果 **不** 走 Cloudflare（DNS 灰云直连），则 A 必须用 ACME 公共证书（Let's Encrypt / ZeroSSL），Origin CA 用不上

### 3.3 三种私钥放置方案

| 方案 | 链路 | 私钥位置 | Pros | Cons |
|---|---|---|---|---|
| **方案 X — Cloudflare 橙云 + Origin CA 在 A** | 客户端 → CF → A(Origin CA 解密) → wg(明文 HTTP) → B | Origin CA 私钥在 A；B 无证书 | 客户端看到 CF 通配符证书；Origin CA 可签 15 年；A↔B 已在 wg 加密通道里 | A 私钥失窃→攻击者可冒充 origin（但需要先绕过 CF 才能用上）；A 看得到 npm token |
| **方案 Y — ACME 公共证书在 A，L7 终止** | 客户端 → A(LE 解密) → wg(明文 HTTP) → B | LE 私钥在 A | 不依赖 Cloudflare；最常见运维模式 | LE 私钥失窃=直接被冒充；A 看到明文 |
| **方案 Z — L4 SNI 透传，私钥在 B** | 客户端 → A(只看 SNI) → wg(密文 TLS) → B(解密) | 证书 + 私钥都在 B | A 失窃≠证书失窃；E2E 加密 | B 要能跑 ACME DNS-01；失去 L7 能力；caddy-l4 仍标"experimental" |

### 3.4 我们的取舍建议

**MVP 阶段采用方案 Y（ACME + L7 在 A）**，理由：

1. 私有 npm registry 的核心威胁是 **未授权访问**，不是中间人 —— 已经在 nftables 锁死端口 + Verdaccio htpasswd / token 鉴权
2. A↔B 那段虽然是 HTTP 明文，但**整段都在 WireGuard ChaCha20-Poly1305 加密通道里**，等同于二次加密
3. L7 必须保留 —— Verdaccio 需要 `X-Forwarded-Proto=https` 才能生成正确 tarball URL，url_prefix 才能正确工作
4. 运维简单：A 上 Caddy 自动 ACME，B 上 Verdaccio 监听明文 HTTP，权责清晰

**进阶（v2）切到方案 Z** 的触发条件：

- A 是共享/低信任 VPS（如 OVH、便宜的小厂）
- 需要满足"零信任"或合规审计（A 不能看到 npm token）
- 业务流量大到担心 A 上 TLS 终止成为性能瓶颈

**不推荐方案 X**：除非已经在用 Cloudflare 代理 `uuhfn.cloud`。引入 Cloudflare 会带来：
- 客户端必须信任 Cloudflare 看到全部明文
- Cloudflare 边缘节点国内访问不稳定（如果团队在墙内）
- 与"Server A 只做 VPN gateway"的极简定位不符

---

## OSS / 参考资料

| Source | URL | 用途 |
|---|---|---|
| Caddy 官方 reverse_proxy 文档 | https://caddyserver.com/docs/caddyfile/directives/reverse_proxy | L7 反代标准做法 |
| Caddy 官方 TLS Options | https://caddyserver.com/docs/caddyfile/options | default_sni / fallback_sni / on_demand_tls |
| **mholt/caddy-l4** (OSS) | https://github.com/mholt/caddy-l4 | L4 SNI 透传插件 |
| caddy-l4 SNI 动态上游示例 | https://github.com/mholt/caddy-l4/blob/master/docs/examples/tls_sni_dynamic_upstreams.md | 透传配置范例 |
| WireGuard 官方 QuickStart | https://www.wireguard.com/quickstart/ | AllowedIPs / PersistentKeepalive 语义 |
| **Pro Custodibus** WireGuard Topologies (blog) | https://www.procustodibus.com/blog/2020/10/wireguard-topologies/ | hub-and-spoke 拓扑权威定义 |
| nftables 官方 wiki | https://wiki.nftables.org/wiki-nftables/index.php/Quick_reference-nftables_in_10_minutes | policy drop / vmap / set 语法 |
| Verdaccio 官方 Reverse Proxy 文档 | https://verdaccio.org/docs/reverse-proxy/ | 必须的 X-Forwarded-* 头 |
| Cloudflare Origin CA 官方文档 | https://developers.cloudflare.com/ssl/origin-configuration/origin-ca/ | Origin CA 适用范围、私钥不可恢复 |

---

## 关键决策汇总（供 implement 阶段直接采用）

1. **拓扑**：WireGuard hub-and-spoke，A 是 hub，B 和白名单 VPS 是 spoke；A 开启 IP forward
2. **反代模式**：Caddy L7 reverse_proxy，监听 A 公网 `:443`，upstream = `10.13.13.2:4873`（B 的 wg0 IP）
3. **证书**：A 上 ACME 自动签发（Let's Encrypt），不引入 Cloudflare 代理
4. **B 的端口防护**：nftables `policy drop` + `iifname "wg0"` 放行 4873/80/443；公网完全静默
5. **白名单 VPS**：通过 wg peer 加入 hub-and-spoke，AllowedIPs 限定到 B 的 wg IP；SSH 应急通道走白名单公网 IP set
6. **Verdaccio 配置**：`listen: 0.0.0.0:4873`、`url_prefix: https://uuhfn.cloud`、`max_users` 关闭（只通过 htpasswd 管理）

## Caveats / 不确定项

- caddy-l4 截至 README 仍标 "experimental … expect breaking changes" — 生产用 L4 透传要锁定 commit
- 是否启用 Cloudflare 橙云未知；本研究默认灰云直连
- Verdaccio v6 与 v5 的 `url_prefix` 行为略有差异，部署前确认版本
- 团队成员客户端是否在墙内 → 若是且 A 是境外 VPS，可能需要在 A 前面再叠一层国内中转（本研究未覆盖）
