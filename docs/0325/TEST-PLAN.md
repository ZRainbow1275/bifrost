# Bifrost 真实服务器测试方案 (2026-03-25)

## 测试环境

| 角色 | OS | 配置 | 网络 |
|------|------|------|------|
| Server B (海外) | Ubuntu 22.04 | 1C1G 20GB SSD | 公网 IP, 带宽 ≥ 30Mbps |
| Server A (国内) | Ubuntu 22.04 | 2C4G 40GB SSD | 公网 IP, 带宽 ≥ 10Mbps, 域名 |
| 客户端 | 任意 | WireGuard + curl | 可达 Server A |

前置条件:
- Server A 可 SSH 登录 Server B
- Server A 有 ICP 备案域名（或跳过 Caddy TLS）
- 已修复 AUDIT-REPORT.md 中的 4 个 BLOCKER

说明:
- Step 0-5 主要验证“基础设施与流量路径”
- Step 6 以后必须补上“公网管理面与配置契约”
- 只有两部分都通过，才能把结果解释为“整套产品已验证”

---

## Step 0: 基础连通性

```bash
# 本地 → Server B
ssh root@<B_IP> "uname -a && docker --version"

# 本地 → Server A
ssh root@<A_IP> "uname -a && docker --version"

# Server A → Server B
ssh root@<A_IP> "curl -so /dev/null -w '%{http_code}' --connect-timeout 5 https://<B_IP>:443"
```

| 检查项 | 期望 |
|--------|------|
| SSH 可登录 | 输出系统信息 |
| Docker ≥ 20.10 | 版本号 ≥ 20.10 |
| A→B 443 可达 | 非超时的 HTTP 状态码 |

---

## Step 1: Server B 部署

```bash
ssh root@<B_IP>
git clone https://github.com/ZRainbow1275/bifrost.git
cd bifrost && chmod +x install.sh scripts/*.sh
sudo ./install.sh --server-b
```

### 验证清单

```bash
# 1.1 Xray 运行
systemctl is-active xray && echo "PASS" || echo "FAIL"

# 1.2 端口监听（注意：Xray 不应该用 443）
ss -tlnp | grep xray
# 期望: 默认端口应为 8443 或其他非 Web 端口，不应与 Caddy 443 冲突

# 1.3 防火墙开放
ufw status | grep $(ss -tlnp | grep xray | awk '{print $4}' | cut -d: -f2)

# 1.4 Caddy 运行（如启用域名）
systemctl is-active caddy 2>/dev/null && echo "PASS" || echo "SKIP"

# 1.5 无端口冲突
[ $(ss -tlnp | grep ':443 ' | wc -l) -le 1 ] && echo "PASS" || echo "FAIL: 443端口冲突"

# 1.6 Xray 配置有效
python3 -m json.tool /usr/local/etc/xray/config.json > /dev/null && echo "PASS" || echo "FAIL"

# 1.7 记录连接信息（Step 2 需要）
cat /root/bifrost/server-b-info.txt 2>/dev/null || echo "手动从部署输出记录"
```

---

## Step 2: Server A 部署

```bash
ssh root@<A_IP>
git clone https://github.com/ZRainbow1275/bifrost.git
cd bifrost && chmod +x install.sh scripts/*.sh
sudo ./install.sh --server-a
# 输入 Step 1 的连接信息
```

### 验证清单

```bash
# 2.1 Xray 客户端运行
systemctl is-active xray && echo "PASS" || echo "FAIL"

# 2.2 隧道连通 (P0 — 最关键测试)
curl -x socks5://127.0.0.1:10808 -so /dev/null -w '%{http_code}' \
  --connect-timeout 10 https://api.anthropic.com
# 期望: 200 或 401

# 2.3 NewAPI 容器
docker ps --format '{{.Names}} {{.Status}}' | grep new-api

# 2.4 NewAPI API 可达
curl -s http://127.0.0.1:3000/api/status | python3 -c "import json,sys;print(json.load(sys.stdin)['success'])"
# 期望: True

# 2.5 ⚠️ 首次访问立即完成初始化
echo "访问 http://127.0.0.1:3000 或 /dashboard，立即完成 New API 初始化并设置强管理员密码"

# 2.6 Caddy HTTPS (如有域名)
curl -sI https://<DOMAIN>/api/status | head -3
```

---

## Step 3: Mihomo 智能路由

```bash
sudo ./install.sh --mihomo
```

### 验证清单

```bash
# 3.1 服务运行
systemctl is-active mihomo && echo "PASS" || echo "FAIL"

# 3.1b Mihomo DNS 监听端口与防火墙一致
ss -ulnp | grep 1053 && grep 'MIHOMO_DNS_PORT=1053' /opt/bifrost/configs/network/iptables-rules.sh
# 期望: Mihomo DNS 监听 1053，且防火墙规则使用同一端口

# 3.2 AI 域名走代理
curl -x http://127.0.0.1:7890 -so /dev/null -w '%{http_code}' \
  --connect-timeout 10 https://api.openai.com/v1/models
# 期望: 401

# 3.3 国内直连
curl -x http://127.0.0.1:7890 -so /dev/null -w '%{http_code}' \
  --connect-timeout 5 https://www.baidu.com
# 期望: 200

# 3.4 流媒体拦截
curl -x http://127.0.0.1:7890 -so /dev/null -w '%{http_code}' \
  --connect-timeout 5 https://www.netflix.com
# 期望: 000 (连接被拒)

# 3.5 NewAPI 通过 Mihomo 代理上游
docker restart new-api && sleep 5
docker exec new-api curl -s https://api.anthropic.com -o /dev/null -w '%{http_code}' --connect-timeout 10
# 期望: 200 或 401
```

---

## Step 4: VPN + 用户管理

```bash
sudo ./install.sh --vpn
sudo ./install.sh --user-mgmt   # 选择添加用户
```

### 验证清单

```bash
# 4.1 WireGuard 运行
systemctl is-active wg-quick@wg0 && echo "PASS" || echo "FAIL"

# 4.2 端口监听
ss -ulnp | grep 51820 && echo "PASS" || echo "FAIL"

# 4.3 用户文件生成
ls /etc/bifrost/vpn/users/<username>/
ls /etc/bifrost/users/guides/<username>-guide.md

# 4.4 WireGuard Endpoint 有效
grep '^Endpoint = ' /etc/bifrost/vpn/users/<username>/wg-<username>.conf
# 期望: Endpoint 不应为空，也不应包含 unknown:51820

# 4.5 VPN 已启用时，split-tunnel 防火墙接管必须 fail-fast
BIFROST_ALLOW_IPTABLES_TAKEOVER=0 bash /opt/bifrost/configs/network/iptables-rules.sh apply
# 期望: 若已存在 VPN_INPUT/VPN_FORWARD，脚本应退出非 0，并提示 BIFROST_ALLOW_IPTABLES_TAKEOVER=1

# 4.6 Headscale 版本解析支持动态/覆盖
BIFROST_HEADSCALE_VERSION=0.28.0 bash -lc 'source scripts/vpn.sh >/dev/null && _vpn_headscale_resolve_version'
# 期望: 输出 0.28.0；未设置覆盖时应能从官方 GitHub Releases 解析出非空版本
```

---

## Step 5: 客户端端到端测试

```bash
# 5.1 导入 VPN 配置到 WireGuard 客户端并连接

# 5.2 VPN 连通
ping -c 3 10.8.0.1

# 5.3 NewAPI 通过 VPN 可达
curl https://<DOMAIN>/api/status

# 5.4 ⭐ 最终测试：AI API 调用
curl -X POST https://<DOMAIN>/v1/chat/completions \
  -H "Authorization: Bearer <API_KEY>" \
  -H "Content-Type: application/json" \
  -d '{"model":"claude-sonnet-4-20250514","messages":[{"role":"user","content":"hi"}]}' \
  -w "\n%{http_code}\n"
# 期望: AI 返回响应 + HTTP 200
```

---

## Step 6: Bifrost API 管理平台

```bash
sudo bash scripts/bifrost-api.sh deploy
```

### 验证清单

```bash
# 6.1 容器运行
docker ps | grep bifrost-api

# 6.2 健康检查
curl http://127.0.0.1:8000/health

# 6.3 注册页面
curl -s https://<DOMAIN>/manage/register | grep -o '<title>.*</title>'

# 6.4 注册 API
curl -X POST https://<DOMAIN>/manage/api/v1/register \
  -H "Content-Type: application/json" \
  -d '{"username":"testuser01"}'

# 6.5 模型列表
curl https://<DOMAIN>/manage/api/v1/models

# 6.6 管理接口
curl -H "X-Admin-Key: <KEY>" https://<DOMAIN>/manage/api/v1/stats/overview

# 6.7 未授权访问必须被拒绝
curl -i https://<DOMAIN>/manage/api/v1/channels
# 期望: 非 200，且不返回渠道数据

# 6.8 错误管理密钥必须被拒绝
curl -i -H "X-Admin-Key: wrong-key" https://<DOMAIN>/manage/api/v1/stats/overview
# 期望: 非 200，且不返回统计数据

# 6.9 运行时环境变量契约
docker exec bifrost-api printenv | grep '^BIFROST_'
# 期望: 至少能看到 BIFROST_NEWAPI_BASE_URL / BIFROST_NEWAPI_ADMIN_TOKEN /
#       BIFROST_ADMIN_KEY / BIFROST_ALLOW_SELF_REGISTER / BIFROST_DEFAULT_QUOTA

# 6.10 注册风控配置面
docker exec bifrost-api printenv | grep 'BIFROST_MAX_REGISTER_PER_DAY\\|BIFROST_RATE_LIMIT_PER_MINUTE' || echo 'MISSING'
# 期望: 若系统声明支持注册风控，这两个变量应有明确配置；缺失则记为缺陷

# 6.11 CORS 来源边界
curl -si -H "Origin: https://evil.example" https://<DOMAIN>/manage/api/v1/models | grep -i 'access-control-allow-origin'
# 期望: 管理面不应对任意 Origin 开放；若出现开放式回显则记为缺陷

# 6.12 /manage/register 页面内请求前缀
curl -s https://<DOMAIN>/manage/register | grep -E "/manage/api/v1/register|/manage/api/v1/register/status"
# 期望: 页面应引用 /manage 前缀下的注册接口；若只出现根路径 /api/v1/register，则会打错后端

# 6.13 /manage/docs 的 OpenAPI 地址
curl -s https://<DOMAIN>/manage/docs | grep -E "/manage/openapi.json"
# 期望: 文档页应引用 /manage/openapi.json；若引用根路径 /openapi.json，则在反代前缀下会失效

# 6.14 注册返回的 base_url 必须是外部可用地址
curl -s -X POST https://<DOMAIN>/manage/api/v1/register \
  -H "Content-Type: application/json" \
  -d '{"username":"testuser02"}'
# 期望: 返回的 base_url 不应包含 host.docker.internal / 127.0.0.1 / localhost

# 6.15 未提供管理密钥的行为语义
curl -i https://<DOMAIN>/manage/api/v1/channels
# 期望: 401/403；若返回 422，说明鉴权边界与参数校验耦合

# 6.16 主安装入口是否暴露管理平台
./install.sh --help | grep -i 'bifrost-api\|manage'
# 期望: 主入口能发现管理平台能力；若无任何入口，则记为产品集成缺陷

# 6.17 Compose 样例配置可静态展开
docker compose -f bifrost-api/docker-compose.yml --env-file bifrost-api/.env.example config >/dev/null
# 期望: 样例环境可被静态验证；不应因为磁盘上不存在 .env 而直接失败

# 6.18 install.sh 帮助输出无权限噪音
./install.sh --help 2>help.err && test ! -s help.err
# 期望: 非 root 查看帮助时不应出现 /var/log 写入权限报错

# 6.19 Docker Engine 版本门禁
docker version --format '{{.Server.Version}}'
# 期望: >= 20.10，否则部署脚本必须拒绝继续使用 host.docker.internal:host-gateway

# 6.20 GitHub 镜像前缀可覆盖
BIFROST_GITHUB_MIRROR_PREFIXES='https://mirror-a.example,https://mirror-b.example' \
  bash -lc 'source scripts/common.sh && github_url_candidates "https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip" | sed -n "2,3p"'
# 期望: 输出顺序与环境变量中的镜像前缀一致；不应仍写死旧镜像提示

# 6.21 3x-ui 官方 CLI 配置入口可用
x-ui setting -port 23456 && x-ui setting -username admin -password test-pass
# 期望: 返回成功；部署脚本应优先走官方 CLI，而不是直接写 sqlite

# 6.22 配置模板与运行态关键契约同步
bash tests/test-in-docker.sh
# 期望: 全量套件通过；当前应看到 `166 通过, 0 失败, 0 跳过`

# 6.23 Bifrost API 管理面合同测试
bash tests/test-in-docker.sh bifrost
# 期望: `/docs` / `/openapi.json` / `/register` 的 `/manage` 前缀契约、管理员鉴权 `401/403`
#       以及默认 same-origin CORS 断言全部 PASS

# 6.24 Windows Git Bash 下的 Docker 容器兼容
bash tests/test-in-docker.sh docker
# 期望: 容器内 `install.sh` / `health-check.sh` 的 `bash -n`、`--help`、`--version`（install）与 `health-check` smoke + report 全部 PASS；
#       其中 `install.sh --help` 首行应直接为 `Bifrost v2.0 - 一键部署脚本`，`--version` 输出应干净为 `Bifrost v2.0.0`
#       不应再出现 `/dev/null -> nul` 或 `/opt/bifrost -> C:/Program Files/Git/opt/bifrost` 的路径转换误伤

# 6.25 健康检查纳入管理面 assurance
bash scripts/health-check.sh --verbose || true
grep -E '"bifrost_api"|"caddy"|"public_manage"' /var/log/bifrost/health.json
# 期望: `health.json` 包含 `bifrost_api` / `caddy` / `public_manage` 三组字段；
#       在真实部署环境中应记录本地 `/health`、管理员鉴权 `401/403`、公网 `/manage/health` `/register` `/docs`
#       的状态码与前缀检查结果，而不再只覆盖底层隧道与系统资源

# 6.26 diagnostics 报告导出降级契约
bash scripts/diagnostics.sh report
# 期望: 缺少 `uptime`/`ping -c` 等单项能力时，诊断脚本应降级并继续生成报告；
#       `/var/log/bifrost` 不可写时应显式回退到 `/tmp/bifrost/diagnostic-report.json`，
#       而不是整份报告直接失败
```

---

## Step 7: 回归测试矩阵

| # | 测试项 | 命令 | 期望 | 优先级 |
|---|--------|------|------|--------|
| 1 | Xray 隧道 | `curl -x socks5://127.0.0.1:10808 https://api.anthropic.com` | 200/401 | P0 |
| 2 | Mihomo AI 路由 | `curl -x http://127.0.0.1:7890 https://api.openai.com` | 401 | P0 |
| 3 | 白名单拦截 | `curl -x http://127.0.0.1:7890 https://www.netflix.com` | 000 | P0 |
| 4 | NewAPI 可达 | `curl http://127.0.0.1:3000/api/status` | success:true | P0 |
| 5 | VPN 连通 | `ping 10.8.0.1` | 可达 | P0 |
| 6 | AI 调用 | `POST /v1/chat/completions` | AI 响应 | P0 |
| 7 | 注册接口 | `POST /manage/api/v1/register` | api_key | P1 |
| 8 | 模型状态 | `GET /manage/api/v1/models` | 列表 | P1 |
| 9 | 国内直连 | `curl -x http://127.0.0.1:7890 https://www.baidu.com` | 200 | P1 |
| 10 | TLS 证书 | `curl -vI https://<DOMAIN>` | TLS 1.3 | P2 |
| 11 | 服务自启 | `reboot && systemctl status xray mihomo` | active | P2 |
| 12 | 健康检查 | `./install.sh --health-check` | 全绿，且 `health.json` 包含 `bifrost_api/caddy/public_manage` | P2 |
| 13 | 管理接口鉴权边界 | `curl -i https://<DOMAIN>/manage/api/v1/channels` | 非 200 | P0 |
| 14 | 错误管理密钥拒绝 | `curl -i -H "X-Admin-Key: wrong" https://<DOMAIN>/manage/api/v1/stats/overview` | 非 200 | P0 |
| 15 | Bifrost 环境变量契约 | `docker exec bifrost-api printenv | grep '^BIFROST_'` | 核心变量齐全 | P1 |
| 16 | 注册风控配置存在 | `docker exec bifrost-api printenv | grep 'BIFROST_MAX_REGISTER_PER_DAY\\|BIFROST_RATE_LIMIT_PER_MINUTE'` | 不缺失 | P1 |
| 17 | 管理面 CORS | `curl -si -H "Origin: https://evil.example" https://<DOMAIN>/manage/api/v1/models` | 非开放式 CORS | P1 |
| 18 | 注册页前缀正确 | `curl -s https://<DOMAIN>/manage/register | grep '/manage/api/v1/register'` | 命中 | P0 |
| 19 | Docs 前缀正确 | `curl -s https://<DOMAIN>/manage/docs | grep '/manage/openapi.json'` | 命中 | P0 |
| 20 | 注册回传外部地址 | `POST /manage/api/v1/register` | `base_url` 不含内部地址 | P0 |
| 21 | 缺失管理密钥语义 | `curl -i https://<DOMAIN>/manage/api/v1/channels` | 401/403 | P1 |
| 22 | 主入口暴露管理平台 | `./install.sh --help \| grep -i 'bifrost-api\|manage'` | 可发现 | P1 |
| 23 | Compose 样例配置可展开 | `docker compose -f bifrost-api/docker-compose.yml --env-file bifrost-api/.env.example config` | 成功 | P1 |
| 24 | 帮助输出无启动噪音 | `./install.sh --help 2>help.err | sed -n '1p' && test ! -s help.err` | stderr 为空，stdout 首行直接为帮助标题 | P2 |
| 25 | Server B Xray 默认非 443 | `ss -tlnp \| grep xray` | 默认端口非 443 | P0 |
| 26 | Mihomo DNS 端口一致 | `ss -ulnp \| grep 1053 && grep 'MIHOMO_DNS_PORT=1053' /opt/bifrost/configs/network/iptables-rules.sh` | 双方一致 | P1 |
| 27 | split-tunnel 防火墙互斥守卫 | `BIFROST_ALLOW_IPTABLES_TAKEOVER=0 bash /opt/bifrost/configs/network/iptables-rules.sh apply` | VPN 链存在时 fail-fast | P0 |
| 28 | WireGuard Endpoint 有效 | `grep '^Endpoint = ' /etc/bifrost/vpn/users/<username>/wg-<username>.conf` | 不为空且不含 `unknown` | P1 |
| 29 | Docker host-gateway 版本门禁 | `docker version --format '{{.Server.Version}}'` | `>=20.10` 或脚本拒绝部署 | P1 |
| 30 | GitHub 镜像前缀覆盖生效 | `source scripts/common.sh && BIFROST_GITHUB_MIRROR_PREFIXES='https://mirror-a.example,https://mirror-b.example' github_url_candidates 'https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip'` | 候选 URL 顺序与覆盖配置一致 | P1 |
| 31 | Headscale 版本覆盖生效 | `BIFROST_HEADSCALE_VERSION=0.28.0 bash -lc 'source scripts/vpn.sh >/dev/null && _vpn_headscale_resolve_version'` | 输出 `0.28.0` | P1 |
| 32 | 3x-ui CLI 配置优先级 | `x-ui setting -port 23456 && x-ui setting -username admin -password test-pass` | 命令成功，脚本无需先写 sqlite | P1 |
| 33 | 全量统一回归 | `bash tests/test-in-docker.sh` | `166 通过, 0 失败, 0 跳过` | P1 |
| 34 | Monitoring health-check cron 契约 | `bash tests/test-in-docker.sh monitoring` | 首次注册、更新已有条目、缺失脚本 fail-fast 全部通过 | P1 |
| 35 | Backup daily cron 契约 | `bash tests/test-in-docker.sh backup` | 首次注册、更新已有条目、缺失 crontab fail-fast 全部通过 | P1 |
| 36 | Bifrost API 合同测试 | `bash tests/test-in-docker.sh bifrost` | 管理面前缀、鉴权、CORS 契约全部通过 | P0 |
| 37 | Git Bash Docker 容器兼容 | `bash tests/test-in-docker.sh docker` | 容器内 `install.sh` + `health-check.sh` 的 `bash -n` / `detect_system()` / `--help` / `--version` / smoke 全部通过，且输出干净 | P1 |
| 38 | 健康检查纳入管理面 assurance | `bash scripts/health-check.sh --verbose || true && grep -E '"bifrost_api"|"caddy"|"public_manage"' /var/log/bifrost/health.json` | 新字段存在且记录管理面状态码/前缀 | P1 |
| 39 | diagnostics 报告导出降级契约 | `bash scripts/diagnostics.sh report` | 单项能力缺失时降级继续，报告可落盘到默认或 fallback 路径 | P1 |
