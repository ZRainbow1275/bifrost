# Bifrost 深度审计报告 (2026-03-25)

三路并行审计：部署链路 + 配置模板 + 端到端流量路径。

---

## BLOCKER (4)

### B1: Server B — Xray 443 与 Caddy 443 端口冲突

- **文件**: `scripts/server-b.sh` 第 315 行, 第 1227 行
- **问题**: `install_xray_server()` 默认 Xray 监听 443/tcp。`deploy_server_b()` 随后安装 Caddy 也绑定 443/tcp。两者在同一端口上冲突。
- **后果**: Caddy 启动失败 — `listen tcp :443: bind: address already in use`。伪装网站和 3x-ui 反向代理不可用。
- **修复**: Xray 默认端口改为 8443，或添加端口冲突检测逻辑。

### B2: Server B — Xray 端口未被防火墙开放

- **文件**: `scripts/server-b.sh` 第 242-518 行
- **问题**: `install_xray_server()` 安装 Xray 后未调用 `_open_firewall_port()`。`deploy_server_b()` 先执行 `setup_firewall()`（UFW 默认 deny incoming），Caddy 仅开放 80/443。若用户选择非 443 端口，该端口在防火墙中关闭。
- **后果**: Server A 的 Xray 客户端连接被防火墙丢弃。VLESS+Reality 隧道无法建立，所有 AI API 请求超时。
- **修复**: `install_xray_server()` 结尾添加 `_open_firewall_port ${xray_port} tcp`。

### B3: Mihomo DNS 端口不匹配

- **文件**: `configs/mihomo/config.yaml.tpl` 第 78 行, `configs/network/iptables-rules.sh` 第 53 行
- **问题**: Mihomo DNS 监听 `0.0.0.0:1053`，但 `iptables-rules.sh` 中 `MIHOMO_DNS_PORT=53`，防火墙仅开放 53 端口给 Docker 子网。Docker 容器无法通过 53 到达 Mihomo DNS（因为它监听在 1053）。
- **后果**: Docker 容器的 DNS 解析失败，NewAPI 无法解析上游 AI API 域名，智能路由失效。
- **修复**: `iptables-rules.sh` 中 `MIHOMO_DNS_PORT=53` 改为 `1053`。

### B4: 两套防火墙脚本互斥

- **文件**: `configs/vpn/iptables-vpn.sh`, `configs/network/iptables-rules.sh`
- **问题**: 两个脚本都全面管理 iptables 规则。`iptables-rules.sh` 的 `flush_rules()` 会清除 `iptables-vpn.sh` 创建的所有链（包括 VPN_INPUT），反之 VPN_INPUT 的 final DROP 会截获所有未匹配的 INPUT 流量。
- **后果**: 部署顺序错误导致 VPN 隔离失效（安全漏洞）或服务中断。
- **修复**: 统一为一套防火墙管理逻辑，或建立执行顺序依赖。

---

## HIGH (7)

### H1: NewAPI 默认密码 root/123456 暴露

- **文件**: `scripts/server-a.sh` 第 962-964 行
- **问题**: NewAPI 使用 `calciumion/new-api:latest` 默认管理员 root/123456。Caddy 反向代理后暴露到公网。从 Caddy 启动到用户手动改密之间存在窗口期。
- **修复**: 部署时自动生成随机管理员密码并输出。

### H2: template_render() sed 转义不完整

- **文件**: `scripts/common.sh` 第 728 行
- **问题**: `sed -e 's/[\/&]/\\&/g'` 只转义 `/` 和 `&`。X25519 Public Key（base64url）可能包含 `+` 等 sed 特殊字符。
- **后果**: Mihomo 配置渲染出错，Mihomo 启动失败。

### H3: GitHub 镜像 URL 可能失效

- **文件**: `scripts/common.sh` 第 1053-1076 行
- **问题**: `github_download()` 依赖 `ghproxy.net`, `mirror.ghproxy.com`, `gh-proxy.com`。这些第三方镜像有频繁下线历史。
- **后果**: 国内网络环境下所有软件包下载失败。

### H4: PUBLIC_IP 变量可能为空

- **文件**: `scripts/vpn.sh` 第 859 行
- **问题**: `_create_wireguard_user()` 中 `server_endpoint="${PUBLIC_IP}:${WG_PORT}"`。如果 `detect_system()` 未被调用，`PUBLIC_IP` 为空。
- **后果**: VPN 客户端配置中 `Endpoint = :51820`，无法连接。

### H5: Docker host-gateway 需 20.10+

- **文件**: `scripts/server-a.sh` 第 882 行
- **问题**: `extra_hosts: "host.docker.internal:host-gateway"` 需要 Docker 20.10+。若系统已有旧版 Docker，`check_docker()` 返回成功跳过重装。
- **后果**: 旧版 Docker 上 NewAPI 代理设置无效。

### H6: 配置模板文件未被使用（死代码）

- **文件**: `configs/xray/server.json.tpl`, `configs/xray/client.json.tpl`, `configs/caddy/Caddyfile-a.tpl`, `configs/caddy/Caddyfile-b.tpl`
- **问题**: 脚本使用 heredoc 内联生成配置，模板文件从未被 `template_render()` 调用。模板与实际配置存在结构性差异。
- **后果**: 修改模板不会影响实际部署，维护混乱。

### H7: install.sh help 中 GitHub URL 未更新

- **文件**: `install.sh` 第 623 行
- **问题**: `项目地址: https://github.com/your-org/bifrost` 未更新为实际地址。
- **修复**: 改为 `https://github.com/ZRainbow1275/bifrost`。

---

## MEDIUM (8)

| # | 问题 | 文件 | 影响 |
|---|------|------|------|
| M1 | Mihomo DNS `0.0.0.0:1053` 无防火墙限制 | config.yaml.tpl:78 | 可被利用为 DNS 放大攻击反射器 |
| M2 | Xray HTTP 代理 `0.0.0.0:10809` 无显式限制 | server-a.sh:389 | UFW deny 保护，但缺少显式规则 |
| M3 | Mihomo `allow-lan:true` + `bind-address:"*"` | config.yaml.tpl:34 | 7890 端口对外暴露为开放代理 |
| M4 | 3x-ui SQLite 直接操作可能与新版不兼容 | server-b.sh:656 | 面板凭据可能未生效 |
| M5 | Headscale 版本硬编码 0.23.0 | vpn.sh:612 | 可能过时 |
| M6 | acme.sh 停止 port 80 服务的 sed 解析不可靠 | server-b.sh:973 | 证书签发失败 |
| M7 | iptables-rules.sh 中端口规则重复 | iptables-rules.sh:49 | 规则表膨胀 |
| M8 | fail2ban 模板 SSH 端口硬编码为默认 22 | jail.local:60 | 独立使用时端口错误 |

---

## 端到端流量路径验证

```
用户设备 (Claude Code)
  │ WireGuard UDP:51820
  ▼
Server A (10.8.0.1)
  │ iptables NAT MASQUERADE
  ▼
Caddy (443/tcp → localhost:3000)
  │ reverse_proxy /v1/*, /api/*
  ▼
NewAPI Docker (127.0.0.1:3000)
  │ HTTP_PROXY=http://host.docker.internal:7890
  ▼
Mihomo (0.0.0.0:7890)
  │ AI域名→AI-Proxy, CN→DIRECT, 流媒体→REJECT, 其余→REJECT
  ▼
Xray Client SOCKS5 (127.0.0.1:10808)
  │ socks-in 全部信任转发到 proxy outbound
  │ VLESS+Reality+Vision, TCP, chrome fingerprint
  ▼
[GFW]
  ▼
Xray Server on Server B (0.0.0.0:PORT)
  │ outbound: freedom (direct)
  ▼
api.anthropic.com / api.openai.com / ...
```

**6 跳端口链验证结果**: 全部匹配（前提：BLOCKER 修复后）。
