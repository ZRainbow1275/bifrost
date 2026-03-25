# =============================================================================
# Mihomo (Meta) Configuration Template - Bifrost
# =============================================================================
# Architecture:
#   Docker (New API) -> HTTP_PROXY -> Mihomo:{{MIHOMO_MIXED_PORT}}
#     -> routing decisions
#       -> Xray SOCKS5 ({{XRAY_UPSTREAM_ADDR}}:{{XRAY_UPSTREAM_PORT}})
#         -> VLESS+Reality tunnel -> Server B -> Internet
#
# Routing strategy: WHITELIST mode
#   - AI services        -> AI-Proxy (via Xray upstream)
#   - Streaming/Social   -> REJECT (block)
#   - China domestic (CN)-> DIRECT
#   - Private/LAN        -> DIRECT
#   - Everything else    -> REJECT (whitelist enforcement)
#
# Placeholders (replaced by template_render):
#   MIHOMO_MIXED_PORT     - Mixed HTTP+SOCKS5 port (default: 7890)
#   MIHOMO_SOCKS_PORT     - Dedicated SOCKS5 port (default: 7891)
#   MIHOMO_API_PORT       - RESTful API port (default: 9090)
#   MIHOMO_API_SECRET     - API authentication secret
#   XRAY_UPSTREAM_ADDR    - Xray SOCKS5 listen address (127.0.0.1)
#   XRAY_UPSTREAM_PORT    - Xray SOCKS5 listen port (10808)
#
# Note: Server B connection details (IP, port, UUID, pubkey, SNI, short ID)
# are passed to template_render but only used in comments below for
# documentation purposes. They are NOT embedded in the config body because
# Mihomo connects to Xray upstream (SOCKS5), not directly to Server B.
# =============================================================================

# --- General Settings ---
mixed-port: {{MIHOMO_MIXED_PORT}}
socks-port: {{MIHOMO_SOCKS_PORT}}
allow-lan: true
bind-address: "*"
mode: rule
log-level: info
ipv6: false

# Performance tuning
unified-delay: true
tcp-concurrent: true
keep-alive-idle: 600
keep-alive-interval: 15
find-process-mode: "off"

# GeoData settings
# geodata-mode: true means geoip uses .dat format (not .metadb/.mmdb)
geodata-mode: true
geo-auto-update: true
geo-update-interval: 168
geodata-loader: standard
geox-url:
  geoip: "https://github.com/MetaCubeX/meta-rules-dat/releases/latest/download/geoip.dat"
  geosite: "https://github.com/MetaCubeX/meta-rules-dat/releases/latest/download/geosite.dat"
  mmdb: "https://github.com/MetaCubeX/meta-rules-dat/releases/latest/download/country.mmdb"
  asn: "https://github.com/MetaCubeX/meta-rules-dat/releases/latest/download/GeoLite2-ASN.mmdb"

# --- External Controller (RESTful API) ---
external-controller: 127.0.0.1:{{MIHOMO_API_PORT}}
secret: "{{MIHOMO_API_SECRET}}"

# --- Profile ---
profile:
  store-selected: true
  store-fake-ip: true

# =============================================================================
# DNS Configuration
# =============================================================================
# Strategy: fake-ip mode for optimal routing performance.
# - Default nameservers (China): Alibaba DNS + Tencent DNSPod
# - Foreign nameservers: Cloudflare + Google (DoH)
# - nameserver-policy: CN domains use domestic DNS, foreign use overseas DNS
# =============================================================================
dns:
  enable: true
  listen: 0.0.0.0:1053
  ipv6: false
  enhanced-mode: fake-ip
  fake-ip-range: 198.18.0.1/16

  # Domains that should NOT receive fake IPs (need real resolution)
  fake-ip-filter:
    - "*.lan"
    - "*.local"
    - "*.localhost"
    - "localhost.ptlogin2.qq.com"
    - "+.srv.nintendo.net"
    - "+.stun.playstation.net"
    - "+.msftconnecttest.com"
    - "+.msftncsi.com"
    - "WORKGROUP"
    # NTP time servers
    - "time.*.com"
    - "time.*.gov"
    - "time.*.edu.cn"
    - "time.*.apple.com"
    - "time-ios.apple.com"
    - "time-macos.apple.com"
    - "ntp.*.com"
    - "+.pool.ntp.org"
    - "*.ntp.org.cn"
    - "time1.cloud.tencent.com"
    # Chinese music/media (need real IP for geo-detection)
    - "music.163.com"
    - "*.music.163.com"
    - "*.126.net"
    - "*.baidu.com"
    - "*.bdstatic.com"

  # Bootstrap DNS (used to resolve DoH server addresses themselves)
  default-nameserver:
    - 223.5.5.5
    - 119.29.29.29

  # Primary nameservers
  nameserver:
    - "https://dns.alidns.com/dns-query#h3=true"
    - "https://doh.pub/dns-query"

  # Per-domain DNS routing policy
  nameserver-policy:
    # China + private domains use domestic DNS
    "geosite:cn,private":
      - "https://dns.alidns.com/dns-query#h3=true"
      - "https://doh.pub/dns-query"
    # Foreign domains use overseas DNS
    "geosite:geolocation-!cn":
      - "https://dns.cloudflare.com/dns-query#h3=true"
      - "https://dns.google/dns-query#h3=true"

# =============================================================================
# Sniffer
# =============================================================================
# Sniffs TLS/HTTP traffic to determine real destination domain.
# Critical for accurate routing when using fake-ip.
# =============================================================================
sniffer:
  enable: true
  force-dns-mapping: true
  parse-pure-ip: true
  override-destination: true
  sniff:
    HTTP:
      ports: [80, 8080-8880]
      override-destination: true
    TLS:
      ports: [443, 8443]
    QUIC:
      ports: [443, 8443]

# =============================================================================
# TUN (disabled - proxy mode only)
# =============================================================================
tun:
  enable: false

# =============================================================================
# Proxies
# =============================================================================
# Xray SOCKS5 upstream: Mihomo forwards proxy-destined traffic to the local
# Xray client, which handles the VLESS+Reality protocol transport to Server B.
# Xray does NO routing; it simply forwards everything it receives.
# =============================================================================
proxies:
  - name: "xray-vless-reality"
    type: socks5
    server: {{XRAY_UPSTREAM_ADDR}}
    port: {{XRAY_UPSTREAM_PORT}}
    udp: true

# =============================================================================
# Proxy Groups
# =============================================================================
# AI-Proxy: url-test group for automatic best-path selection.
#   Health check: periodically test api.anthropic.com reachability.
# Fallback: fallback group that switches to next node on failure.
# DIRECT / REJECT: built-in actions exposed as selectable groups.
# =============================================================================
proxy-groups:
  - name: "AI-Proxy"
    type: url-test
    proxies:
      - "xray-vless-reality"
    url: "https://api.anthropic.com"
    interval: 300
    timeout: 5000
    lazy: true
    tolerance: 100

  - name: "Fallback"
    type: fallback
    proxies:
      - "xray-vless-reality"
    url: "https://www.gstatic.com/generate_204"
    interval: 300
    timeout: 5000
    lazy: true

  - name: "DIRECT"
    type: select
    proxies:
      - DIRECT

  - name: "REJECT"
    type: select
    proxies:
      - REJECT

# =============================================================================
# Rule Providers
# =============================================================================
# External ruleset files for maintainability. These are loaded from disk
# and auto-reloaded at the specified interval.
# =============================================================================
rule-providers:
  ai-domains:
    type: file
    behavior: classical
    path: ./ruleset/ai-domains.yaml
    interval: 86400

  streaming-block:
    type: file
    behavior: classical
    path: ./ruleset/streaming-block.yaml
    interval: 86400

# =============================================================================
# Rules
# =============================================================================
# Evaluation order: top to bottom, first match wins.
#
# Strategy: WHITELIST mode
#   1. Private/LAN        -> DIRECT (always accessible)
#   2. Ads                -> REJECT (block)
#   3. Streaming/Social   -> REJECT (block abuse)
#   4. AI services        -> AI-Proxy (allowed, routed through Xray)
#   5. China domestic     -> DIRECT (no proxy needed)
#   6. Private networks   -> DIRECT
#   7. MATCH (everything) -> REJECT (whitelist enforcement)
# =============================================================================
rules:
  # --- 1. Private/LAN traffic -> DIRECT (must be first) ---
  - IP-CIDR,127.0.0.0/8,DIRECT,no-resolve
  - IP-CIDR,10.0.0.0/8,DIRECT,no-resolve
  - IP-CIDR,172.16.0.0/12,DIRECT,no-resolve
  - IP-CIDR,192.168.0.0/16,DIRECT,no-resolve
  - IP-CIDR,169.254.0.0/16,DIRECT,no-resolve
  - IP-CIDR,224.0.0.0/4,DIRECT,no-resolve
  - IP-CIDR6,::1/128,DIRECT,no-resolve
  - IP-CIDR6,fc00::/7,DIRECT,no-resolve
  - IP-CIDR6,fe80::/10,DIRECT,no-resolve

  # --- 2. Block advertisements ---
  - GEOSITE,category-ads-all,REJECT

  # --- 3. Block streaming/social media (from ruleset) ---
  - RULE-SET,streaming-block,REJECT

  # --- 4. AI services -> proxy (from ruleset) ---
  - RULE-SET,ai-domains,AI-Proxy

  # --- 5. China domestic -> DIRECT ---
  - GEOSITE,cn,DIRECT
  - GEOIP,CN,DIRECT,no-resolve

  # --- 6. Private/internal sites -> DIRECT ---
  - GEOSITE,private,DIRECT
  - GEOIP,private,DIRECT,no-resolve

  # --- 7. Whitelist enforcement: block everything not matched above ---
  - MATCH,REJECT
