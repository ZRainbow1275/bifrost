# Server A 极简化 / 隐蔽伪装 / 安全加固策略 v2

> **核心反转**：实测发现腾讯云对**任意端口**的 HTTP/HTTPS 流量都做 L7 监测（SNI/Host header）。未备案则发 RST。详见 §1 证据链。
>
> 结论：Server A **不能暴露任何 Web 服务到公网**（含 80/443/8443/非标 HTTPS 全死）。Bifrost 默认 Caddy 监听公网 443 的模式在国内未备案场景**完全行不通**。
>
> 本文档：**在保留 Bifrost 原技术栈（WireGuard + Caddy + Mihomo + Xray + dnsmasq + fail2ban）的前提下**，重新调度 Server A 的端口策略，把 Caddy 移到 VPN 内网，让公网仅暴露 1 个 UDP（VPN）+ 1 个 TCP（SSH）。

---

## 0. 三大设计约束（不可妥协）

| 约束 | 依据 |
|---|---|
| **公网零 80/443** | 腾讯云未备案 IP 上 HTTP/HTTPS 必死 |
| **Caddy 必须保留** | 用户偏好 + 自动 TLS 价值 + Bifrost 原生模板可复用 |
| **不大改 Bifrost 技术栈** | WG / dnsmasq / fail2ban / Mihomo / Xray / Caddy 全部保留 |

---

## 1. 证据链：为什么 Server A 公网无 HTTP/HTTPS

### 1.1 腾讯云官方政策

[腾讯云 ICP 备案文档](https://cloud.tencent.com/document/product/243/19630)：

> "**是否需要备案的判断条件是（网站/域名）或 APP 还是 80 端口？**
> 托管于中国境内服务器的网站或 APP 需要完成备案。**不论设置哪个端口都能被监测到。**"

[腾讯云 ICP 阻断文档](https://cloud.tencent.com/document/product/243/20220)：

> "不支持备案的域名指向中国大陆地区云服务器会被阻断"
> "您网站或者 APP 需在腾讯云做接入备案，否则将被腾讯云未备案监测系统识别并阻断域名的访问服务"

→ 官方明文：**任意端口的 HTTP/HTTPS 都拦**。

### 1.2 用户实测验证

[V2EX 1082505 实测帖](https://www.v2ex.com/t/1082505)：

> "腾讯云即使是非 80、443 端口指向国内服务器仍然会被拦截，提示未备案"
> "https 协议有 SNI 字段，靠这个识别，还是会封禁"
> "现在都是 layer 7 DPI，逃不了"
> "运营商在监听到 http req 或 tls clientHello 中 SNI 未备案时两边各发几个 RST"

技术拦截机制：

- 流量入口处 DPI 扫 `SNI` (TLS) 和 `Host` header (HTTP)
- 匹配到"未备案域名" 或 "腾讯云非己备案的域名" → 双向 RST
- 与端口无关，仅看 L7 协议特征

### 1.3 三个可能的逃逸路径（均有缺陷）

| 路径 | 缺陷 |
|---|---|
| 公网纯 IP HTTPS（无 SNI） | 客户端必须 OS 级支持 IP cert SAN，npm/docker 客户端不可靠；几天后仍可能被识别封 |
| SNI 用真实大公司域名（如 microsoft.com） | 这就是 Reality 的做法，但要求"看着像访问外网"，Server A 作为入站服务身份不对 |
| 客户端 + 服务端协同丢弃 RST | hack 方案，长期不稳，且不解决主动探测 |

**结论**：Server A 公网根本不开 HTTP/HTTPS，从协议层规避问题。

---

## 2. Server A 端口布局（最终）

### 2.1 公网（eth0）

| 端口 | 协议 | 服务 | 公网画像 |
|---|---|---|---|
| **41194**（示例，可动态变） | UDP | WireGuard + QUIC 混淆 | "某用户在跑 BT/游戏/HTTP3 客户端" |
| **60022** | TCP | sshd + admin IP allowlist | "某用户开了非默认 SSH" |
| 其余 1-65535 | — | nftables `drop` | 全闭 |

**关键设计**：

- ❌ 80/tcp 不开（避免 HTTP 备案监测）
- ❌ 443/tcp 不开（避免 HTTPS SNI 备案监测）
- ❌ 443/udp 不开（同样有 SNI 监测，QUIC 也看 Initial Packet SNI）
- ✅ 高位 UDP（WG）：腾讯云对 UDP 高位端口监管最弱
- ✅ 高位 TCP SSH：经典做法，加 IP 白名单后无暴露面

**WG UDP 端口选择策略**：

- 避开 53、443、500、1194、4500、51820 这些 VPN/熟知端口
- 选 30000-65000 范围内随机端口
- 可启用 **port hopping**（端口跳变，每 N 分钟换一次，AmneziaWG 支持）

### 2.2 VPN 内网（wg0 = 10.8.0.1/24）

| 端口 | 服务 | 用途 |
|---|---|---|
| 22 | sshd | 管理 SSH（与公网 60022 分流） |
| 53 | dnsmasq | DNS 解析（含 `*.mirror.lan`） |
| 80 | Caddy | 重定向到 443 |
| 443 | Caddy | 内网反代入口（TLS via internal CA） |
| 8080 | Caddy（可选） | 管理面 / 状态页 |
| 9090 | Mihomo external-controller | 管理面 |

→ 所有"业务面"全部仅 VPN 可见。员工必须先 WG 连接，才能访问。

### 2.3 本地 loopback（127.0.0.1）

| 端口 | 服务 | 用途 |
|---|---|---|
| 10800 | Xray client (dokodemo-door) | Mihomo 转发目标 |
| 10801 | Xray API | 本地管理 |
| 7895 | Mihomo TPROXY | nftables 重定向目标 |

---

## 3. Caddy 在 Server A 的角色重定义

### 3.1 监听位置

**改 Bifrost 原 `Caddyfile-a.tpl` 的核心点**：把 `{{DOMAIN}}` 公网站点块**整体替换**为 `*.mirror.lan` 内网站点块。

```caddyfile
# Global options
{
    email admin@mirror.lan
    
    # 服务器协议
    servers {
        protocols h1 h2 h3
        trusted_proxies static private_ranges
    }
    
    # 不向公网发起 ACME（避开 80/443/Cloudflare 等外联）
    # 用 Caddy local CA 自签 *.mirror.lan
    # 也可改为 DNS-01 + Cloudflare（见 §3.3）
    
    # 日志
    log {
        output file /var/log/caddy/caddy.log {
            roll_size 50MiB
            roll_keep 3
            roll_keep_for 168h
        }
        level WARN
    }
}

# VPN-only 强制 snippet
(vpn_required) {
    @nonvpn not remote_ip 10.8.0.0/24 127.0.0.0/8
    handle @nonvpn {
        # 公网或非 VPN 来源直接 abort（不返回 403 暴露存在）
        abort
    }
}

# 安全头
(sec_headers) {
    header {
        X-Content-Type-Options "nosniff"
        X-Frame-Options "DENY"
        Referrer-Policy "no-referrer"
        -Server
    }
}

# 大文件流式
(large_file) {
    request_body { max_size 10GB }
    reverse_proxy {
        transport http {
            read_timeout 1800s
            write_timeout 1800s
        }
    }
}

# ============================================================
# 内网入口（仅监听 wg0，不绑定公网）
# ============================================================
*.mirror.lan {
    bind 10.8.0.1
    tls internal             # Caddy local CA 自签
    
    import vpn_required
    import sec_headers
    
    # 统一审计日志（每域名一行）
    log {
        output file /var/log/caddy/access.log {
            roll_size 50MiB
            roll_keep 5
        }
        format json
    }
    
    # npm 镜像 → 经 Xray 隧道到 B
    @npm host npm.mirror.lan
    handle @npm {
        reverse_proxy 127.0.0.1:10800 {
            header_up Host npm.mirror.lan
            header_up X-Forwarded-For {remote_host}
        }
    }
    
    @docker host docker.mirror.lan
    handle @docker {
        reverse_proxy 127.0.0.1:10800 {
            header_up Host docker.mirror.lan
            header_up X-Forwarded-For {remote_host}
            transport http {
                read_timeout 600s
            }
        }
    }
    
    @gh host gh.mirror.lan
    handle @gh {
        reverse_proxy 127.0.0.1:10800 {
            header_up Host gh.mirror.lan
        }
    }
    
    @hf host hf.mirror.lan
    handle @hf {
        reverse_proxy 127.0.0.1:10800 {
            header_up Host hf.mirror.lan
            transport http {
                read_timeout 1800s
            }
        }
    }
    
    @api host api.mirror.lan
    handle @api {
        reverse_proxy 127.0.0.1:10800 {
            header_up Host api.mirror.lan
            transport http {
                response_header_timeout 300s
                read_timeout 600s
            }
        }
    }
    
    # 内网门户（伪装站，员工访问 portal.mirror.lan 看到公司主页）
    @portal host portal.mirror.lan
    handle @portal {
        root * /var/www/portal
        file_server
    }
    
    handle { abort }
}

# HTTP→HTTPS 重定向（仅内网）
http://*.mirror.lan {
    bind 10.8.0.1
    redir https://{host}{uri} permanent
}
```

**关键点**：

- `bind 10.8.0.1` 强制只监听 wg0 接口（公网 nmap 看不到）
- `tls internal` 用 Caddy local CA 自签，免域名免外联
- `import vpn_required` 双保险：即便监听错暴露公网，也 abort
- 反代目标 `127.0.0.1:10800` 是 Xray dokodemo-door 入口，由 Xray 决定 Reality 出向到 B
- 大文件 vhost（docker/hf）单独配 read_timeout 1800s

### 3.2 内网门户（"伪装站"新定义）

用户多次强调"伪装站必须保留"。在新方案下，重定义伪装站：

| 旧定义（公网伪装） | 新定义（内网门户伪装） |
|---|---|
| 公网访问 A 时看到假公司站 | 公网根本看不到 Caddy |
| 抗主动探测 | 抗员工误用（员工访问 A 时看到的不是 Bifrost 管理界面，是公司内网门户） |
| 用 Bifrost 默认模板 | 用真实公司内容（IT 公告、规章、镜像使用指南） |

→ portal.mirror.lan 实际承担：

- 镜像服务使用文档
- AI 网关 API key 自助申请入口（HTML 表单 → 后端调 Bifrost manage API）
- 内部 IT 公告
- VPN 客户端下载链接

→ **员工进 VPN → 浏览器开 portal.mirror.lan → 一站式自助**。"伪装"含义升级为"用户体验门户"。

### 3.3 Caddy ACME 选项对比

| 方案 | 工作量 | 证书来源 | 缺陷 |
|---|---|---|---|
| **Caddy `tls internal`**（推荐） | 0 | 本地 CA 自签 `*.mirror.lan` | 员工首次需预装根证书 |
| DNS-01 via Cloudflare | 中 | Let's Encrypt 公开证书 | 需 CF API token + Caddy 出网到 LE，可能被审 |
| `tls /path/cert /path/key` | 低 | 手动上传 | 续期靠人 |

→ **首选 `tls internal`**。理由：

- 不需要任何外联（不出网 → 抗 GFW 影响）
- 不需要域名（`*.mirror.lan` 是局域命名）
- 不需要 DNS-01 token（少一份凭据泄漏面）
- Caddy 自动滚动签发 + 续期，零运维

证据：[Caddy 官方文档](https://caddy.guide/docs/caddyfile/patterns) 明确支持 `tls internal` 用作私有 PKI。

**员工预装根证书脚本**（用户接入文档附带）：

```bash
# Server B 上拿 root CA（Caddy 部署后生成）
ssh admin@10.8.0.1 'cat /var/lib/caddy/.local/share/caddy/pki/authorities/local/root.crt' > bifrost-root.crt

# Linux 员工
sudo cp bifrost-root.crt /usr/local/share/ca-certificates/
sudo update-ca-certificates

# macOS 员工
sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain bifrost-root.crt

# Windows 员工（PowerShell admin）
Import-Certificate -FilePath bifrost-root.crt -CertStoreLocation Cert:\LocalMachine\Root
```

---

## 4. WireGuard 配置加固（保留协议本体）

### 4.1 端口与 ListenPort

```ini
# /etc/wireguard/wg0.conf

[Interface]
PrivateKey = <server_priv>
Address = 10.8.0.1/24
ListenPort = 41194        # 高位随机，避开 51820/1194 等熟知 VPN 端口
MTU = 1280                # 留余地给后续 QUIC 混淆封装
SaveConfig = false

# 启动时装载 nftables 规则
PostUp = /usr/sbin/nft -f /etc/nftables.d/wg-up.nft
PostDown = /usr/sbin/nft -f /etc/nftables.d/wg-down.nft

# DNS 推送
PostUp = systemctl restart dnsmasq

[Peer]
# 员工 1
PublicKey = <client_pub_1>
AllowedIPs = 10.8.0.10/32
PresharedKey = <psk>      # 启用 PSK 增加抗量子破解
```

### 4.2 WG 混淆方案（可选，渐进启用）

WG 默认握手有 DPI 指纹（首包前 4 字节 `0x01000000`）。三档强度：

**Level 1**：仅高位端口（最简单）

- 改 `ListenPort` 到 30000-65000 随机
- 添加 PostUp 定期变换端口（端口跳变）
- 抗弱 DPI 足够，但被动指纹仍能识别

**Level 2**：udp2raw / phantun 包装

```
[Client]<--TCP/443 (fake HTTP)-->[udp2raw]<--UDP-->[WG :41194]
                                       本地loopback
```

- 客户端先连 udp2raw（伪装 TCP 443）
- udp2raw 解包后转 WG 真实 UDP 端口
- 优点：流量看着像 TCP HTTPS
- 缺点：性能损失 10-15%，多一个进程

**Level 3**：AmneziaWG（推荐）

```ini
[Interface]
PrivateKey = ...
ListenPort = 41194
Address = 10.8.0.1/24

# AmneziaWG 混淆字段（保留 WG 协议核心）
Jc = 4                    # Junk packets count
Jmin = 50
Jmax = 1000
S1 = 50
S2 = 100
H1 = <random_uint32>      # 自定义 magic
H2 = <random_uint32>
H3 = <random_uint32>
H4 = <random_uint32>
```

- 完全兼容 WG 协议骨干，仅在头部加随机填充破指纹
- Bifrost `scripts/vpn.sh` 改动小：`wg` → `awg` 命令替换
- 客户端 Amnezia 全平台 GUI 支持
- 性能与原版 WG 等同

→ **建议路径**：先 Level 1（最快上线）→ 观察 1-2 周 → 出现 DPI 阻断再升 Level 3。

### 4.3 与 Bifrost 现有 `vpn.sh` 的集成

```diff
# scripts/vpn.sh 关键修改点

- WG_PORT=51820
+ WG_PORT="${BIFROST_WG_PORT:-$(shuf -i 30000-65000 -n 1)}"

  # 持久化端口（首次安装时写入 .env）
+ echo "BIFROST_WG_PORT=${WG_PORT}" >> /etc/bifrost.env

- ListenPort = 51820
+ ListenPort = ${WG_PORT}

  # 可选混淆开关
+ if [ "${BIFROST_WG_OBFUSCATION}" = "amneziawg" ]; then
+     # 替换为 AmneziaWG 工具链
+     install_amneziawg
+     # 生成 Jc/Jmin/Jmax/S1/S2/H1-H4 随机值
+     gen_awg_obfuscation_params
+ fi
```

---

## 5. nftables 严格规则（核心安全闸）

```nft
#!/usr/sbin/nft -f
# /etc/nftables.conf

flush ruleset

table inet bifrost {
    # 公网允许 IP（管理 SSH）
    set ssh_admin_allow {
        type ipv4_addr
        elements = { 1.2.3.4, 5.6.7.8 }    # 管理员 IP
    }
    
    # SSH 暴破限速
    set ssh_rate {
        type ipv4_addr
        flags dynamic, timeout
        timeout 1h
    }
    
    chain input {
        type filter hook input priority filter; policy drop;
        
        # 1. loopback
        iif "lo" accept
        
        # 2. 已建立连接
        ct state established,related accept
        ct state invalid drop counter
        
        # 3. ICMP 限速
        ip protocol icmp limit rate 10/second accept
        ip6 nexthdr ipv6-icmp limit rate 10/second accept
        
        # 4. 公网 WG UDP 端口（变量化）
        iifname "eth0" udp dport $WG_PORT accept
        
        # 5. 公网 SSH（白名单 + 速率）
        iifname "eth0" tcp dport 60022 ip saddr @ssh_admin_allow \
            meter ssh_meter size 1024 \
            { ip saddr limit rate 3/minute burst 3 packets } \
            accept
        
        # 6. VPN 内网全放
        iifname "wg0" accept
        
        # 7. 其余记录后丢弃
        counter log prefix "FW-DROP: " level warn limit rate 5/minute drop
    }
    
    chain forward {
        type filter hook forward priority filter; policy drop;
        
        # VPN 流量出向：交给 Mihomo TPROXY 处理
        iifname "wg0" ct state new,established,related accept
        oifname "wg0" ct state established,related accept
        
        counter drop
    }
    
    chain output {
        type filter hook output priority filter; policy accept;
    }
    
    # NAT
    chain prerouting {
        type nat hook prerouting priority dstnat;
    }
    
    chain postrouting {
        type nat hook postrouting priority srcnat;
        # VPN 客户端访问公网时（如有需要）走 A 公网
        ip saddr 10.8.0.0/24 oifname "eth0" masquerade
    }
    
    # Mihomo TPROXY mangle
    chain prerouting_mangle {
        type filter hook prerouting priority mangle;
        # 由 mihomo 启动时 PostUp 注入具体规则
    }
}
```

**关键**：

- 公网 input policy = `drop`（默认拒绝）
- 只放行 WG UDP 端口 + admin IP 的 SSH
- 内网 wg0 全放（Caddy/dnsmasq/Mihomo 都在这）
- 出向 policy = accept（A 自身要发 Xray 包到 B）
- log prefix 触发的丢包会进 journald，便于审计

---

## 6. Mihomo 配置（保留 + 优化）

延续 Bifrost 原 Mihomo 角色（路由决策 + 流量管控）：

```yaml
# /etc/mihomo/config.yaml（关键段）

mixed-port: 0
tproxy-port: 7895
allow-lan: false
bind-address: '10.8.0.1'         # 仅 wg0

mode: rule
log-level: warning
ipv6: false

# 内存优化（关键）
geodata-mode: true
geodata-loader: memconservative    # 省 30% 内存
geo-auto-update: false

# 管理面仅 VPN
external-controller: '10.8.0.1:9090'
external-ui: ''
secret: '<64hex_random>'

# 内置 DNS（与 dnsmasq 并存：dnsmasq 解析 *.mirror.lan → 10.8.0.1；
# 其余域名由 Mihomo DNS 处理路由分流）
dns:
  enable: true
  listen: '10.8.0.1:5353'         # Mihomo 占 5353，dnsmasq 占 53 转发部分给 Mihomo
  enhanced-mode: redir-host
  default-nameserver:
    - 119.29.29.29
    - 223.5.5.5
  nameserver:
    - https://dns.alidns.com/dns-query
    - https://doh.pub/dns-query
  fallback:
    - tls://1.1.1.1:853
    - tls://8.8.8.8:853
  fallback-filter:
    geoip: true
    geoip-code: CN

# Xray 出口
proxies:
  - name: "to-server-b"
    type: vless
    server: 127.0.0.1
    port: 10800

proxy-groups:
  - name: "PROXY"
    type: select
    proxies: ["to-server-b"]

rule-providers:
  reject:
    type: http
    behavior: domain
    url: "<reject_url>"
    path: ./rules/reject.yaml
    interval: 86400
  ai:
    type: file
    behavior: classical
    path: ./rules/ai-domains.yaml
  mirror:
    type: file
    behavior: classical
    path: ./rules/mirror-domains.yaml

rules:
  # 优先黑名单（流媒体、社交、敏感）
  - RULE-SET,reject,REJECT
  
  # 镜像域名（mirror.lan 走 Caddy local，不出 A）
  - DOMAIN-SUFFIX,mirror.lan,DIRECT
  
  # AI 走代理
  - RULE-SET,ai,PROXY
  
  # 镜像源站（npmjs/docker.io 等）走代理
  - RULE-SET,mirror,PROXY
  
  # 国内域名/IP 直连
  - GEOSITE,cn,DIRECT
  - GEOIP,CN,DIRECT
  
  # 私有网段
  - IP-CIDR,10.0.0.0/8,DIRECT,no-resolve
  - IP-CIDR,172.16.0.0/12,DIRECT,no-resolve
  - IP-CIDR,192.168.0.0/16,DIRECT,no-resolve
  
  # 默认拒绝（防员工随便上海外站）
  - MATCH,REJECT
```

**dnsmasq 与 Mihomo DNS 协作**：

```conf
# /etc/dnsmasq.conf

interface=wg0
bind-interfaces
listen-address=10.8.0.1
port=53

# 内网域名
address=/.mirror.lan/10.8.0.1
address=/portal.mirror.lan/10.8.0.1

# 其他全转发给 Mihomo
server=10.8.0.1#5353
```

→ dnsmasq 是前端入口（员工 DNS 指向 10.8.0.1:53），mirror.lan 直接返回；其余分发给 Mihomo:5353 做路由决策。

---

## 7. Xray Client 精简（仅本地 + outbound）

```json
{
  "log": {
    "loglevel": "warning",
    "access": "none"
  },
  "inbounds": [
    {
      "tag": "from-mihomo",
      "listen": "127.0.0.1",
      "port": 10800,
      "protocol": "dokodemo-door",
      "settings": {
        "address": "0.0.0.0",
        "network": "tcp,udp",
        "followRedirect": false
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls"],
        "metadataOnly": false
      }
    }
  ],
  "outbounds": [
    {
      "tag": "reality-to-b",
      "protocol": "vless",
      "settings": {
        "vnext": [{
          "address": "<SERVER_B_IP>",
          "port": 443,
          "users": [{
            "id": "<UUID>",
            "encryption": "none",
            "flow": "xtls-rprx-vision"
          }]
        }]
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "serverName": "www.microsoft.com",
          "fingerprint": "chrome",
          "publicKey": "<PUB_KEY>",
          "shortId": "<SHORT_ID>",
          "spiderX": "/"
        }
      },
      "mux": {
        "enabled": true,
        "concurrency": 8
      }
    }
  ],
  "routing": {
    "rules": [
      {"type":"field","inboundTag":["from-mihomo"],"outboundTag":"reality-to-b"}
    ]
  }
}
```

→ Server A 出向 Server B:443 走 Reality。从 GFW 视角：A 在"访问 microsoft.com"。这是合规出向（向公网大公司访问），不触发 SNI 备案告警。

→ Reality 必须在 B（海外）服务端，A 仅作 client。Bifrost 原架构这部分不动。

---

## 8. fail2ban 保留 + 精简

Bifrost 原栈保留 fail2ban，但作用域收窄：

```ini
# /etc/fail2ban/jail.d/bifrost.local

[sshd]
enabled = true
port = 60022
filter = sshd
logpath = /var/log/auth.log
maxretry = 3
findtime = 600
bantime = 86400
ignoreip = 127.0.0.1/8 10.8.0.0/24 1.2.3.4 5.6.7.8

[caddy-internal-403]
enabled = false        # 内网 Caddy 不暴露，无暴破风险

[wireguard]
enabled = false        # WG 无登录概念，不适用
```

→ 仅守 SSH 公网入口。Caddy 不暴露所以不需要。

→ 内存约 25-30MB，与 nftables meter 互补（meter 处理瞬时洪水，fail2ban 处理长期暴破并永久封禁）。

---

## 9. 进程清单 + 内存预算

| 进程 | 状态 | RSS |
|---|---|---|
| 内核 + page cache buffer | 必须 | ~400 MB |
| systemd-journald | 必须 | ~30 MB |
| sshd | 必须 | ~10 MB |
| nftables（内核态） | 必须 | ~5 MB |
| WireGuard / AmneziaWG（内核态） | 必须 | ~30 MB |
| **Caddy**（vpn-only + tls internal） | 保留 | ~80 MB |
| **dnsmasq** | 保留 | ~20 MB |
| **Mihomo**（memconservative） | 保留 | ~50 MB |
| **Xray client**（精简） | 保留 | ~50 MB |
| **fail2ban** | 保留 | ~30 MB |
| **总计** | | **~705 MB** |
| 2C2G 余量 | | **~1.25 GB** |

→ 比 Bifrost 默认（公网 Caddy + New API + MySQL 在 A）的 ~1.45GB 节省 **~750MB**。

→ 仍配 **4GB swap** + `vm.swappiness=10`，防 Mihomo 规则集突发加载。

---

## 10. 公网攻击面（外部探测视角）

```bash
$ nmap -sS -sU -p- -T4 <ServerA_IP>

PORT       STATE       SERVICE
41194/udp  open|filtered  unknown
60022/tcp  filtered       (除非源 IP 在白名单)
其余        closed/filtered

$ nmap -sV -p 41194 <ServerA_IP> --version-all
41194/udp  open|filtered  unknown (no version info)

$ hping3 -2 -p 41194 -c 5 <ServerA_IP>
(无响应或随机字节，WG 未授权握手不回包)

$ curl https://<ServerA_IP>/
(connection refused or timeout)

$ openssl s_client -connect <ServerA_IP>:443
connect:errno=111
```

→ 公网视角：A 像"一台开了非默认 SSH 的私人 VPN 服务器"。不属于 Web 服务范畴，不触备案监管。

腾讯云未备案监测系统的工作模式（来源 [V2EX](https://www.v2ex.com/t/1082505)）：

- 监测 80/443 + 任意端口的 HTTP/HTTPS L7
- A 公网无任何 HTTP/HTTPS（连看着像的都没有）
- → 监测系统**无触发点**，A 保持长期稳定

---

## 11. Server A → Server B 隧道（保留 Bifrost 原设计）

```
A:127.0.0.1:10800 (Xray client dokodemo) 
  → outbound VLESS+Reality
  → B:443 (Xray server Reality)
  → 解封装
  → Caddy on B:443（根据 Host 路由）
  → npm/docker/gh/hf/dl/api 各服务
```

A 上 Xray 配置见 §7。B 上是 Bifrost 原 `scripts/server-b.sh` 流程（含 3x-ui + Reality + Caddy + 各镜像 docker-compose），不重写。

**Server B 端口策略**（海外无监管）：

- 443/tcp Xray Reality（公网入口）
- 80/tcp Caddy（80 → 443 redirect，给 LE HTTP-01 用）
- 22/tcp sshd（admin allowlist）
- 3x-ui 面板：仅监听 wg0（或独立 admin VPN）

---

## 12. 部署顺序（DD 后）

```
Phase 0: DD 重装
  1. 选 Debian 12 minimal 镜像
  2. 重装两台机
  3. 关闭腾讯云监控 agent 残留（DD 后应已无）
     ps aux | grep -iE 'tencent|barad|cloudmonitor'

Phase 1: 系统基线（两机）
  4. 改 hostname / timezone / 安装基础包
  5. SSH key 部署 + sshd_config 加固
  6. sysctl 调优（BBR / fastopen / file-max / forwarding）
  7. unattended-upgrades 仅 security
  8. nftables 装载（含 SSH 白名单）

Phase 2: Server A 极简栈
  9. 安装 WireGuard（或 AmneziaWG）
  10. /etc/wireguard/wg0.conf（高位端口）
  11. systemctl enable --now wg-quick@wg0
  12. dnsmasq 装 + 配置（mirror.lan 解析）
  13. Mihomo 装 + 配置 + systemd service
  14. Xray 装 + outbound 配 + systemd service
  15. Caddy 装（带 cloudflare DNS 插件可选）
  16. /etc/caddy/Caddyfile（§3 内网模板）
  17. /var/www/portal/ 部署门户内容
  18. fail2ban + sshd jail
  19. nftables 上线（严格规则）
  20. journald 限额 + 转发到 B（可选 rsyslog）

Phase 3: Server B 全栈
  21. Bifrost 原 scripts/server-b.sh 流程
  22. Reality 服务端 + 3x-ui
  23. Caddy + 镜像 docker-compose（含 New API + PG）
  24. 内网测试 A→B 隧道

Phase 4: 联调
  25. 员工设备装根证书
  26. 员工 WG client 配置签发
  27. 员工 DNS = 10.8.0.1
  28. 测试 https://portal.mirror.lan / https://npm.mirror.lan
  29. 测试 docker pull docker.mirror.lan/library/alpine
  30. 测试 New API 调用 api.mirror.lan/v1/...

Phase 5: 加固验证
  31. 外部 nmap A 公网（应只见 41194/udp + 60022/tcp）
  32. testssl A 公网（应连不上）
  33. curl 测 SNI 备案绕过（应被 RST，证明纯 IP 直连无 Web）
  34. 内存使用 free -h（应 <800MB）
  35. 备份脚本：仅 /etc/wireguard /etc/caddy /etc/mihomo /etc/xray 加密上传 B
```

---

## 13. Bifrost 项目代码改动清单

### 13.1 `scripts/server-a.sh`

```diff
# 公网 Caddy 部署部分整体替换为内网部署
- render_caddyfile_a_public
+ render_caddyfile_a_internal

# 新增 WG 端口随机化
+ if [ -z "${BIFROST_WG_PORT}" ]; then
+     BIFROST_WG_PORT=$(shuf -i 30000-65000 -n 1)
+     echo "BIFROST_WG_PORT=${BIFROST_WG_PORT}" >> /etc/bifrost.env
+ fi

# 新增 SSH 端口分离（公网 60022 + 内网 22）
+ configure_dual_ssh

# 新增 nftables 严格模板
+ install_strict_nftables

# 删除 New API 部署（迁 B）
- deploy_new_api_compose

# 删除公网 ACME（改 tls internal 或留待 B 处理）
- configure_acme_renewal
```

### 13.2 `configs/caddy/`

- 新增 **`Caddyfile-a-internal.tpl`**（§3.1 内容）
- 保留 `Caddyfile-a.tpl` 作为"有备案场景"备选模板
- 新增 `Caddyfile-a-portal.html.tpl`（员工门户内容）

### 13.3 `configs/vpn/`

- WG 配置加 `ListenPort = {{WG_PORT}}` 占位
- 新增 `awg-template.conf`（AmneziaWG 模板，含 H1-H4 占位）

### 13.4 `configs/nftables/`

- 新增 `nftables-a-strict.conf`（§5 内容）

### 13.5 `scripts/user-management.sh`

```diff
add_user() {
    local username=$1
    
    # WG 凭据
    generate_wg_keys $username
    write_wg_peer $username
    
    # 客户端配置打包
+   generate_client_bundle $username
    # bundle 含：
    #   - wg0.conf（含 Endpoint=A:WG_PORT, DNS=10.8.0.1, AllowedIPs=10.8.0.0/24,B_IP/32）
    #   - bifrost-root.crt（Caddy local CA）
    #   - .npmrc 片段
    #   - daemon.json 片段
    #   - .gitconfig 片段
    #   - README-onboarding.md
}
```

### 13.6 `docs/`

- 新增 `docs/SERVER-A-STEALTH.md`（说明本文档落地后的运维差异）
- 更新 `docs/CLIENT-SETUP.md`（员工预装 CA + 多镜像配置）
- 更新 `docs/SECURITY.md`（公网攻击面变化）

---

## 14. 风险与权衡

| 风险 | 影响 | 缓解 |
|---|---|---|
| WG 高位 UDP 端口被腾讯云画像 | VPN 慢/丢包 | 启用 AmneziaWG L3 混淆；准备多端口池随时切换 |
| 员工误装根证书在公司其他设备 | 内部 PKI 泄漏 | 部署用脚本签发，员工接入时一次完成；CA 私钥永不离开 A |
| Caddy local CA 私钥泄漏 | 内网 TLS 失效 | `/var/lib/caddy/.local/share/caddy/pki/` 权限 700；纳入加密备份 |
| 公网 SSH 白名单 IP 漂移 | 管理员失联 | 双通道：admin 远端 IP 白名单 + 应急 console；定期更新白名单 |
| Server B 出境 Reality dest 站失效 | 隧道中断 | dest 池 + 自动健康检查 + 定时切换 |
| Mihomo 默认拒绝太严 | 员工合法访问被拦 | 申请白名单流程（portal 自助申请）+ 灰度名单 |
| 腾讯云风控规则升级（封 UDP 高端口） | A 无法接入 | 备用方案：Cloudflare Argo Tunnel 替代直连，或换其他云厂商 |
| Caddy 2.x 局域 CA 行为变更 | tls internal 失效 | 锁定 Caddy 版本；用 docker 部署带 digest |

---

## 15. 验证清单（外部探测）

部署后做：

```bash
# 1. 端口画像（公网视角）
nmap -sS -sU -p 1-65535 -T4 --top-ports 1000 <ServerA_IP>
# 期望仅见 41194/udp (open|filtered) + 60022/tcp (admin allowlist 外为 filtered)

# 2. 主动 SNI 探测（应无响应或 RST）
echo | openssl s_client -connect <ServerA_IP>:443 -servername anything.com
# 期望: connect:errno=111

# 3. HTTP 探测
curl -v http://<ServerA_IP>/ --connect-timeout 5
curl -v https://<ServerA_IP>/ --connect-timeout 5
# 期望: Connection refused

# 4. WG 探测（未授权握手应无回包）
hping3 -2 -p 41194 -c 5 -d 8 <ServerA_IP>
# 期望: 100% packet loss

# 5. Caddy 内网可达性（从员工 VPN）
curl --resolve portal.mirror.lan:443:10.8.0.1 https://portal.mirror.lan/
# 期望: 200 OK + portal HTML

# 6. mirror 反代链路
curl --resolve npm.mirror.lan:443:10.8.0.1 https://npm.mirror.lan/-/ping
# 期望: 200 OK（经 A Caddy → Xray → B verdaccio）

# 7. Mihomo 默认拒绝
curl --resolve www.youtube.com:443:142.250.X.X https://www.youtube.com/
# 期望: 内网不通（被 Mihomo REJECT）

# 8. 内存
ssh admin@10.8.0.1 'free -h && ps aux --sort=-%mem | head -10'
# 期望: used < 800M
```

---

## 16. 与 v1 对比

| 维度 | v1（前文档） | v2（本文档） |
|---|---|---|
| 公网端口 | 80/tcp + 443/tcp/udp + SSH | **仅 1 UDP + 1 SSH** |
| Caddy 位置 | 删除 → 换 nginx | **保留，移入 wg0 内网** |
| dnsmasq | 删除 | **保留**（与 Mihomo DNS 协作） |
| fail2ban | 删除 → 换 nftables meter | **保留**（守 SSH 公网） |
| Bifrost 改动量 | 大（多处替换） | **中**（端口策略 + 内网监听 + Caddy 模板） |
| 备案监管 | 80/443 仍触发监测 | **零触发**（无 HTTP/HTTPS 公网入口） |
| 自动 TLS | 自签 CA | **Caddy local CA + tls internal**（原生） |
| 伪装站 | 公网模板假站 | **内网门户**（员工自助 + 审计入口） |
| 员工体验 | 需配多套客户端证书 | **单一 bundle**（WG + CA + 配置） |
| 内存预算 | ~640 MB | ~705 MB（多 80MB Caddy + 30MB fail2ban） |
| 隐蔽性 | 端口画像像 CDN（但 443 触雷） | **像私人 VPN 服务器**（公网零 Web） |

---

## 17. 总结：极简 × 隐蔽 × 安全 三角

```
                        极简 (Minimal)
                       公网仅 2 个端口
                            ▲
                           / \
                          /   \
                    v2 ✦/     \
                        /       \
                       /         \
        安全 ◄────────/───────────\─────► 隐蔽
   (Security)                          (Stealth)
   双层闸                            纯 UDP + SSH
   (nftables + Mihomo                 无 HTTP/HTTPS
    默认拒绝 + 内网证书)               无备案触发点
```

**v2 核心权衡**：

- ✅ **保留 Bifrost 原栈**（WG + dnsmasq + fail2ban + Mihomo + Xray + Caddy 全在）
- ✅ **公网零 80/443**（彻底规避备案监管）
- ✅ **Caddy 价值放大**（成为内网员工统一入口）
- ✅ **配置自动 TLS**（tls internal 零续期）
- ⚠️ **代价**：员工首次接入需预装根证书（一次性）
- ⚠️ **代价**：管理员公网 SSH 走 60022，依赖 admin IP 白名单（IP 漂移要维护）

---

## 18. 给 Bifrost 项目方的建议（基于本方案）

1. **新增 `BIFROST_SERVER_A_PROFILE` 模式**：
   - `public-decoy`（旧默认，有备案场景）
   - `private-internal`（本文档方案，无备案场景）← **推荐设为默认**
   - `hybrid`（公网 + 内网双 Caddy）

2. **WG 端口随机化** 默认开启：
   - 安装时 `shuf -i 30000-65000 -n 1`
   - 持久化到 `/etc/bifrost.env`
   - 客户端配置生成时自动读取

3. **AmneziaWG 可选启用**：
   - `BIFROST_WG_OBFUSCATION=amneziawg` 触发
   - 模板自动生成随机 H1-H4
   - 客户端 bundle 同步输出 AWG 配置

4. **员工门户模板** 内置：
   - `configs/caddy/portal/index.html`
   - 含镜像使用指南、API key 申请表单（接 Bifrost manage API）

5. **根证书分发自动化**：
   - `user-management.sh add` 输出 zip bundle
   - 含 OS 检测脚本 + 一键安装根证书

6. **腾讯云风控适配**：
   - `scripts/cloud-detect.sh`：识别腾讯云/阿里云/华为云
   - 国内云强制 `private-internal` profile

---

> 文档版本：v2.0 · 2026-05-18
> 替换：v1.0（AmneziaWG 替换 WG / 删 Caddy / nginx 真站克隆方案被推翻）
> 适用：Bifrost 架构 + 国内未备案 2C2G + 海外 8C16G 双节点
> 关键证据：腾讯云 ICP 备案文档 + V2EX 1082505 用户实测 + Caddy 2.10 tls internal 官方文档
