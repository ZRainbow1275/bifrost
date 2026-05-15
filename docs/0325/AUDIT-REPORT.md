# Bifrost 深度审计报告 (2026-03-25)

三路并行审计：部署链路 + 配置模板 + 端到端流量路径。

---

## 审计边界校正

当前报告已经对 `ai-gateway-bridge/` 的基础设施链路做了深审，重点覆盖：
- Server A / Server B 部署顺序与端口占用
- Xray / Mihomo / Docker / iptables 的数据路径闭环
- 模板渲染、配置一致性与脚本级安全问题

但按照 `PROJECT-SPEC.md` 的产品边界，**Bifrost 不只是一组部署脚本**，还包含 `bifrost-api/` 这一公网管理面（注册、模型状态、渠道管理、统计）。

因此，当前结论只能视为：
- 已完成：`ai-gateway-bridge/` 基础设施与流量路径深审
- 尚未完成：面向整套产品的最终签收审计

若要把“审查完成”解释为“整套产品可放行”，必须把下文的“产品级补审项”纳入范围。

---

## 2026-03-27 第三轮补审更新（代码级盲区修复）

上一轮把 `bash tests/test-in-docker.sh all` 的通过结果写成了“脚本层与产品级补审项已闭环”的核心证据，但后续补审证明这里仍有 4 个测试盲区：

- `scripts/backup.sh` 会把主 payload 归档覆盖成只剩 metadata 的错误包；同时首次生成新备份 key 时，`_get_encryption_key()` 会把日志和 key 一起写到 stdout，导致首次备份实际使用了错误口令。
- `scripts/uninstall.sh` 会按宽关键词删除 crontab，误删用户自己的 `health-check` / `rkhunter` 任务。
- `scripts/server-b.sh` 在 `acme.sh` 官方下载失败时会退化到第三方 mirror 的 `curl | sh`。
- `scripts/security.sh` / `scripts/server-b.sh` 的仓库 key 引导曾允许 `gpg --dearmor` 失败后继续推进，形成 trust bootstrap fail-open。

本轮已完成代码级修复并补齐回归：

- **R7 已修复**: `scripts/backup.sh` 现在先把 configs payload 与 metadata staging 到临时目录，再一次性打包；不再出现 `.tar.gz` 被 metadata 覆盖的问题。新增内容级测试验证归档内同时存在 `configs/*` 与 `metadata/*`。
- **R8 已修复**: `scripts/backup.sh:_get_encryption_key()` 生成新 key 时改为把提示日志写到 stderr，stdout 只返回纯口令，消除“首次备份可生成但无法按 key 文件解密”的问题。
- **R9 已修复**: `scripts/uninstall.sh` 改为只删除精确的 Bifrost cron marker / owned script 路径，并显式清理 `rkhunter-scan` / `lynis-audit` 这两个由本项目创建的系统 cron 文件；新增边界测试验证不会误删用户自有 `health-check` / `rkhunter` 任务。
- **R10 已修复**: `scripts/server-b.sh` 的 `acme.sh` fallback 已收敛到官方 GitHub source 文件下载后再执行，不再允许第三方 mirror 的 `curl | sh`。
- **R11 已修复**: `scripts/server-b.sh` 与 `scripts/security.sh` 的仓库 key bootstrap 现在都会在 `gpg --dearmor` 失败时明确报错并中止，拒绝继续信任未完成校验的仓库。
- **T1 已补齐**: `tests/test-in-docker.sh` 新增 `uninstall` 与 `supply` 契约套件，并把 `security`、`keepalive`、`backup`、`monitoring`、`vpn` 扩展为“控制面 fail-fast + 成功摘要一致性”双层验证。本轮继续补上 `fail2ban / auto-updates / security tools installer / SSH restart-path override / SSH safety revert / rkhunter weekly cron runtime` 这几批高价值安全合同后，2026-03-28 当前最新代码级回归结果为：
  - `bash tests/test-in-docker.sh security` → `28 通过, 0 失败, 0 跳过`
  - `bash tests/test-in-docker.sh all` → `308 通过, 0 失败, 0 跳过`
  - 当前已无环境性 `skip`；host-side 合同与 Docker 容器阶段均已重新打绿。

## 2026-03-25 第二轮补审更新（已复测）

以下问题已在本轮修复并完成最小运行验证，不再按“未修复风险”计入阻断：

- **B5 已修复**: `scripts/server-a.sh` 的真实 Caddy heredoc 已加入 `/manage*` 反代，并显式上送 `X-Forwarded-Prefix: /manage`。
- **B6 已修复**: `bifrost-api/app/main.py` 改为自定义 `/docs`、`/redoc`、`/openapi.json`；`register.html` 注入 `api_prefix`。本地 `TestClient` 已验证 `url: '/manage/openapi.json'`、`/manage/docs/oauth2-redirect` 与 `data-api-prefix="/manage"` 均命中。
- **B1 已修复**: `scripts/server-b.sh` 已将 Server B 的 Xray 默认监听端口从 `443` 改为 `8443`，并在输入 `80/443` 时直接拒绝，避免与 Caddy Web 入口冲突；模板 fallback 与健康检查 fallback 也已同步到 `8443`。
- **B2 已修复**: `install_xray_server()` 在 Xray 服务启动成功后已显式调用 `_open_firewall_port "${listen_port}" tcp "Xray Server"`，消除“服务已启动但端口仍被默认防火墙拦截”的问题。
- **B3 已修复**: `configs/network/iptables-rules.sh` 已把 `MIHOMO_DNS_PORT` 从 `53` 改到 `1053`，与 `configs/mihomo/config.yaml.tpl` 的真实监听端口一致。
- **B4 已修复为 fail-fast 缓解**: `configs/network/iptables-rules.sh` 新增 firewall ownership guard；当检测到 `VPN_INPUT` / `VPN_FORWARD` 已存在时，`apply` / `flush` 会直接退出并要求显式设置 `BIFROST_ALLOW_IPTABLES_TAKEOVER=1`。本地已完成 `bash -n` 与 stubbed `iptables` 行为验证，确认脚本会输出拒绝 takeover 的错误并以非 0 退出。
- **H1 已重新核验并修正部署引导**: 依据当前 New API 官方安装文档，Docker/Compose 首次访问会进入初始化页面创建管理员账号与密码，而不是固定 `root/123456`。`scripts/server-a.sh` 与测试计划中的默认口令提示已改为“首次访问立即完成初始化并设置强密码”。
- **H2 已修复**: `template_render()` 现在会同时转义 `\`、`/`、`&`，并改用 `printf` 传递模板内容，避免 `sed` replacement 误改渲染值。本地 smoke test 已验证 `a\b/c&d` 能原样写入输出模板。
- **H3 已修复**: GitHub 下载/查询/clone 链路已统一收敛到 `scripts/common.sh` 的可配置镜像策略。当前可通过 `BIFROST_GITHUB_MIRROR_PREFIXES` 覆盖默认镜像前缀，`github_download()` / `github_fetch_text()` / `github_clone_repo()` 会依次尝试直连与配置镜像，用户提示与排障文档也已改成“覆盖配置”而非承诺某个第三方镜像永远可用。
- **H4 已修复**: `_create_wireguard_user()` 在生成客户端配置前会先自检 `PUBLIC_IP`；自动探测失败时，交互场景会要求显式输入，非交互场景会 fail-fast，而不再写出 `Endpoint = :51820` 或 `unknown:51820`。
- **H5 已修复**: `scripts/server-a.sh` 与 `scripts/bifrost-api.sh` 现在都会在部署前强制校验 Docker Engine 版本，未满足 `20.10+` 时拒绝继续使用 `host.docker.internal:host-gateway` 依赖链。
- **H8 已修复**: `register.py` 在缺失 `BIFROST_PUBLIC_BASE_URL` 时返回 `503`，`scripts/bifrost-api.sh` 部署时会强制提示输入公网 AI 网关 URL；本地验证 `POST /api/v1/register` 在该变量缺失时返回 `503`。
- **H9 已修复**: `install.sh` 已新增 `--bifrost-api` 入口，并在 Server A 主流程后提供继续部署 Bifrost API 的交互入口；`./install.sh --help` 已验证能发现该能力。
- **M9 / G3 已修复**: 管理鉴权与 CORS 语义已收紧。本地验证结果为 `missing -> 401`、`wrong -> 403`、默认无 allowlist 时 `OPTIONS` 返回 `405` 且不带 `Access-Control-Allow-Origin`；显式 allowlist 命中时仅放行允许来源。
- **G2 已修复并补证**: 注册风控已落地到持久化状态文件，容器 worker 收敛为 `1`，`docker-compose.yml` / `.env.example` 已暴露相关变量。本地以真实状态文件写入 `daily_counts=7` 后，`GET /api/v1/register/status` 返回 `remaining_today=43`。

本轮验证中还发现并修复了 6 个运行期回归问题：

- **R1 已修复**: `BIFROST_NEWAPI_ADMIN_TOKEN` 缺失时，管理接口此前会误报为上游 `502`。现在正确返回 `503 服务端未配置 NewAPI 管理令牌`。
- **R2 已修复**: `bifrost-api/docker-compose.yml` 之前因为 `env_file: .env` 对磁盘 `.env` 形成硬依赖，导致 `docker compose ... --env-file bifrost-api/.env.example config` 无法通过。现已改为显式环境变量映射，样例配置展开验证通过。
- **R3 已修复**: `scripts/common.sh` 之前把主日志写到 `/var/log/bifrost.log`，与现有 logrotate 的 `/var/log/bifrost/*.log` 目录策略漂移，且 `./install.sh --help` 在非 root 场景会报权限错误。现已统一到 `/var/log/bifrost/bifrost.log`，并验证帮助输出不再出现该权限噪音。
- **R4 已修复**: `scripts/health-check.sh` 之前仍停留在“隧道 + NewAPI + 系统资源”层，无法覆盖 `bifrost-api`、`caddy` 与公网 `/manage` 面的真实可用性。现已把本地 `/health`、管理员鉴权 `401/403` 语义、`https://<DOMAIN>/manage/health`、`/manage/register`、`/manage/docs` 及前缀契约纳入统一健康检查，并将结果落入 `/var/log/bifrost/health.json`。
- **R5 已修复**: `scripts/common.sh` 之前在被 `source` 时会无条件打印 `common.sh loaded successfully.`，并通过全局 `EXIT` trap 调用 `_spinner_stop()` 向 stdout 注入回车清屏序列，导致 `./install.sh --help` / `--version` 这类 CLI 输出被启动噪音污染。现已把加载日志改为显式调试开关 `BIFROST_TRACE_COMMON_LOAD=1` 才输出，同时让 spinner 清理只在真实 spinner 运行且终端可交互时发生；`install.sh` 也不再为 `--help` / `--version` 这类参数预先创建目录。
- **R6 已修复**: `scripts/diagnostics.sh` 之前对基础命令缺失和报告目录权限缺乏防御式处理：在缺少 `uptime` 的环境里会直接 `127` 退出，非 root / 本地预演环境下也无法导出报告；同时 Git Bash 下的 `ping -c` 失败会被误报成 `100% loss`。现已改为单项降级而非整份报告失败，并在 `/var/log/bifrost` 不可写时自动回退到 `/tmp/bifrost`；对当前壳层不支持的 `ping` 标志会显式标记 `SKIP`。
- **M6 已修复**: `server-b.sh` 不再尝试从 `ss -tlnp` 输出中用 `sed` 解析 systemd 服务名；当前实现只会临时停止受支持的受管 Web 服务（`caddy/nginx/apache2/httpd`），否则直接 fail-fast 并打印 port 80 监听者，避免证书签发期间误停错服务或假成功。
- **M5 已修复**: `vpn.sh` 不再把 Headscale 固定为 `0.23.0`。当前优先读取 `BIFROST_HEADSCALE_VERSION`，否则通过官方 GitHub Releases API 动态解析最新版本；对非 `apt` 发行版也不再假定存在 RPM 包，而是回退到上游发布的 Linux 二进制安装。
- **M4 已修复**: `server-b.sh` 配置 3x-ui 时已改为官方 `x-ui setting -port/-username/-password` CLI 优先，SQLite 直写只保留为 legacy fallback，不再把数据库 schema 当成稳定契约。
- **H6 已修复为显式契约**: `configs/xray/*.tpl` 与 `configs/caddy/*.tpl` 已明确为测试 parity fixture，而不是误导性的“隐藏运行态入口”。本轮已把 Server A `/manage` 前缀头、Server B `/xui-panel/*` 路径等关键差异补齐，并把这些对齐点加入 `tests/test-in-docker.sh` 自动检查。
- **M7 已修复**: `configs/network/iptables-rules.sh` 已把 Mihomo TCP 端口集合去重，避免 `MIHOMO_HTTP_PORT=7890` 与 `MIHOMO_MIXED_PORT=7890` 时重复追加同一批 `INPUT` 规则。
- **M8 已确认关闭（误报）**: `configs/fail2ban/jail.local` 中的 `port = ssh` 只是静态模板示例；真实部署路径由 `scripts/security.sh` 依据 `_get_ssh_port()` 动态生成 `/etc/fail2ban/jail.local`，会写入实际 SSH 端口而不是硬编码 22。
- **M1 / M2 / M3 已重新定级并关闭**: 当前 `configs/network/iptables-rules.sh` 已明确把 `1053` 仅放行给 Docker 子网，并把 `7890/7891/10809` 收敛到 `localhost + VPN_SUBNET + SERVICE_SUBNET`，其他来源统一进入 `AI_GW_LOG_DROP` 且最终落到默认 `INPUT DROP`。旧结论来自脱离真实防火墙策略单读监听地址/模板，已不再代表当前行为。
- **H7 已确认关闭**: `install.sh` 的帮助页项目地址已是 `https://github.com/ZRainbow1275/bifrost`，此前报告旧条目属于文档未回写。

截至 2026-03-26 本轮再回写时，脚本层与产品级补审项（`G1-G5`）都已完成证据闭环；后续若继续深挖，应转向真实部署环境中的 live certificate / domain / upstream health / runbook 演练，而不是继续在静态脚本层重复开新条目。当前 `./install.sh --health-check` 已是这条 live assurance 路径的第一道门禁，而不再只是底层进程探活。

---

## 历史 BLOCKER（6，均已修复）

### B1: Server B — Xray 443 与 Caddy 443 端口冲突

- **涉及文件**: `scripts/server-b.sh`
- **历史问题**: Xray 默认监听 `443/tcp`，与随后部署的 Caddy Web 入口冲突。
- **当前状态**: 已修复。默认监听端口已改为 `8443`，并在输入 `80/443` 时直接拒绝。
- **验证**: `bash tests/test-in-docker.sh all` 已通过相关端口与帮助输出回归。

### B2: Server B — Xray 端口未被防火墙开放

- **涉及文件**: `scripts/server-b.sh`
- **历史问题**: `install_xray_server()` 完成后未同步开放实际监听端口。
- **当前状态**: 已修复。脚本已显式调用 `_open_firewall_port "${listen_port}" tcp "Xray Server"`。
- **验证**: 端口一致性与脚本语法回归均通过。

### B3: Mihomo DNS 端口不匹配

- **涉及文件**: `configs/mihomo/config.yaml.tpl`, `configs/network/iptables-rules.sh`
- **历史问题**: Mihomo 实际监听 `1053`，但 iptables 仍按 `53` 放行。
- **当前状态**: 已修复。`MIHOMO_DNS_PORT` 已统一为 `1053`。
- **验证**: `bash tests/test-in-docker.sh all` 中的 DNS 端口契约检查通过。

### B4: 两套防火墙脚本互斥

- **涉及文件**: `configs/vpn/iptables-vpn.sh`, `configs/network/iptables-rules.sh`
- **历史问题**: 两套脚本都尝试全面接管 iptables，存在 silent breakage 风险。
- **当前状态**: 已修复为 fail-fast 缓解。检测到 `VPN_INPUT` / `VPN_FORWARD` 时会拒绝 takeover，除非显式设置 `BIFROST_ALLOW_IPTABLES_TAKEOVER=1`。
- **剩余限制**: 这仍不是统一防火墙编排的终态，只是先阻断静默破坏。

### B5: Server A 真实生效的 Caddy 配置没有 `/manage/*` 反向代理

- **涉及文件**: `scripts/server-a.sh`, `configs/caddy/Caddyfile-a.tpl`, `scripts/bifrost-api.sh`
- **历史问题**: 模板承诺 `/manage/*`，但真实 heredoc 配置未兑现。
- **当前状态**: 已修复。运行时 Caddy 配置已加入 `/manage*` 反代，并显式上送 `X-Forwarded-Prefix: /manage`。
- **验证**: 模板/运行态 parity 检查与 Bifrost 合同测试均已通过。

### B6: `/manage/*` 前缀下注册页和 Swagger Docs 会打错后端

- **涉及文件**: `bifrost-api/app/main.py`, `bifrost-api/app/templates/register.html`, `bifrost-api/app/routers/register.py`
- **历史问题**: 注册页与 OpenAPI 文档页此前引用根路径，反代到 `/manage/*` 时会请求错目标。
- **当前状态**: 已修复。应用已根据 `X-Forwarded-Prefix` 生成 `/manage/openapi.json` 与 `data-api-prefix="/manage"`；本轮还额外修复了 `register_page()` 对 `TemplateResponse` 的旧式调用顺序，解决当前依赖组合下 `/register` 直接报错的问题。
- **验证**: `bash tests/test-in-docker.sh bifrost` 通过。

---

## 历史 HIGH（9，均已修复或关闭）

### H1: NewAPI 初始化引导曾错误提示默认密码 `root/123456`

- **涉及文件**: `scripts/server-a.sh`, `docs/0325/TEST-PLAN.md`
- **当前状态**: 已修复。部署与测试计划都改为“首次访问立即完成初始化并设置强密码”。

### H2: `template_render()` sed 转义不完整

- **涉及文件**: `scripts/common.sh`
- **当前状态**: 已修复。当前实现会同时转义 `\`、`/`、`&`，并用 `printf` 传递模板内容。

### H3: GitHub 镜像 URL 可能失效

- **涉及文件**: `scripts/common.sh`
- **当前状态**: 已修复。镜像前缀已统一为共享配置，支持 `BIFROST_GITHUB_MIRROR_PREFIXES` 覆盖。

### H4: `PUBLIC_IP` 变量可能为空

- **涉及文件**: `scripts/vpn.sh`
- **当前状态**: 已修复。当前函数会先自动探测公网 IPv4，必要时交互输入，否则 fail-fast。

### H5: Docker `host-gateway` 依赖 20.10+

- **涉及文件**: `scripts/server-a.sh`, `scripts/bifrost-api.sh`
- **当前状态**: 已修复。部署前会明确拒绝低于 `20.10` 的 Docker Engine。

### H6: 配置模板文件未被使用（死代码）

- **涉及文件**: `configs/xray/*.tpl`, `configs/caddy/*.tpl`
- **当前状态**: 已修复为显式测试契约。模板现在作为 parity fixture 纳入统一回归，而不是伪装成隐藏运行态入口。

### H7: `install.sh --help` 中 GitHub URL 未更新

- **涉及文件**: `install.sh`
- **当前状态**: 已关闭。当前帮助页实际输出已指向 `https://github.com/ZRainbow1275/bifrost`。

### H8: 默认部署下自助注册返回的 `base_url` 会退化为内部地址语义

- **涉及文件**: `scripts/bifrost-api.sh`, `bifrost-api/docker-compose.yml`, `bifrost-api/app/routers/register.py`
- **当前状态**: 已修复。部署时会强制要求 `BIFROST_PUBLIC_BASE_URL`，缺失时注册接口返回 `503`，不再静默回退到内部地址语义。

### H9: `bifrost-api` 模块未接入主安装入口 `install.sh`

- **涉及文件**: `install.sh`, `scripts/bifrost-api.sh`
- **当前状态**: 已修复。主入口已提供 `--bifrost-api` CLI 与交互式接入路径。

---

## 历史 MEDIUM（10，均已修复或关闭）

| # | 问题 | 文件 | 影响 |
|---|------|------|------|
| M1 | [已关闭] Mihomo DNS `0.0.0.0:1053` 仅放行 Docker 子网，其他来源受默认 `INPUT DROP` | iptables-rules.sh:300-304 | 旧结论脱离真实防火墙策略 |
| M2 | [已关闭] Xray HTTP 代理 `0.0.0.0:10809` 已限制为 localhost/VPN/SERVICE 来源 | iptables-rules.sh:331-336 | 监听地址不等于公网可达 |
| M3 | [已关闭] Mihomo `allow-lan:true` + `bind-address:"*"` 已由防火墙收敛至内网来源 | iptables-rules.sh:331-336 | 当前不构成开放代理 |
| M4 | [已修复] 3x-ui 配置改为官方 CLI 优先，SQLite 仅作 legacy fallback | server-b.sh:656 | 避免直接依赖易漂移的数据库 schema |
| M5 | [已修复] Headscale 版本不再硬编码，支持 GitHub Releases 动态解析 / 环境变量覆盖 | vpn.sh:612 | 避免继续钉死旧版本 |
| M6 | [已修复] acme.sh 停止 port 80 服务的 sed 解析不可靠 | server-b.sh:973 | 已改为仅停止受支持的受管服务，否则 fail-fast |
| M7 | [已修复] iptables-rules.sh 中 Mihomo 端口规则已去重 | iptables-rules.sh:49 | 避免重复追加 `7890` 规则 |
| M8 | [已关闭] fail2ban 模板 SSH 端口硬编码为默认 22 | jail.local:60 | 真实部署由 security.sh 按实际 SSH 端口生成 |
| M9 | [已修复] 管理端点缺少 `X-Admin-Key` 时已稳定返回 `401`，错误密钥返回 `403` | `bifrost-api/app/dependencies.py` | 鉴权语义已与合同测试对齐 |
| M10 | [已修复] 默认空 allowlist 下不再对任意 Origin 开放 CORS | `bifrost-api/app/main.py` | 默认已回到 same-origin 边界 |

---

## 产品级补审项（2026-03-26 已纳入并关闭）

### G1: 审计范围已扩展到 `bifrost-api/` 主攻击面（已关闭）

- **证据**: 当前报告已直接覆盖 `bifrost-api/app/main.py`、`app/dependencies.py`、`app/routers/register.py`、`app/routers/models.py`、`README.md`、`.env.example`、`docker-compose.yml`，不再只停留在 `scripts/` / `configs/`。
- **验证**: `tests/test-in-docker.sh` 已新增 `bifrost`、`monitoring`、`backup` 合同测试入口，并在 2026-03-26 本机通过 `bash tests/test-in-docker.sh bifrost`、`bash tests/test-in-docker.sh monitoring`、`bash tests/test-in-docker.sh backup` 与 `bash tests/test-in-docker.sh all` 完成回归。
- **结论**: 本报告已从“部署层深审”升级为“产品级 assurance audit”。

### G2: 注册风控已收敛为持久化状态 + 配置透传（已修复）

- **证据**:
  - `bifrost-api/app/routers/register.py` 现已使用 `_load_registration_state()` / `_save_registration_state()` / `_reserve_registration_attempt()` / `_mark_registration_success()` 管理日配额与分钟级限流。
  - `bifrost-api/.env.example` 与 `bifrost-api/docker-compose.yml` 现已暴露 `BIFROST_MAX_REGISTER_PER_DAY`、`BIFROST_RATE_LIMIT_PER_MINUTE`、`BIFROST_REGISTRATION_STATE_FILE`。
  - `bifrost-api/Dockerfile` 已收敛到 `uvicorn ... --workers 1`，避免本地状态文件与多 worker 语义冲突。
- **验证**: 本地已验证真实状态文件中的 `daily_counts=7` 会被 `GET /api/v1/register/status` 正确折算为 `remaining_today=43`。
- **限制**: 该实现已经满足单机/单容器部署的真实风控需求；如果未来要横向扩容，状态仍应继续下沉到共享持久层。

### G3: 管理面 CORS 已默认回到 same-origin（已修复）

- **证据**: `bifrost-api/app/main.py` 仅在显式配置 `BIFROST_CORS_ALLOW_ORIGINS` 时才挂载 `CORSMiddleware`；默认空 allowlist 下不再开放任意来源。
- **验证**: 2026-03-26 合同测试已验证 `OPTIONS /api/v1/register/status` 在 `Origin: https://evil.example` 下返回 `405` 且不带 `Access-Control-Allow-Origin`。
- **结论**: 旧的“开放式 CORS”结论已不再代表当前行为。

### G4: 文档、环境变量与反代前缀契约已对齐（已关闭）

- **证据**:
  - `bifrost-api/README.md` 已明确 `/api/v1/models` 是公开聚合查询端点，`/api/v1/models/test` 才是管理员主动探测端点。
  - `bifrost-api/README.md`、`bifrost-api/.env.example`、`bifrost-api/docker-compose.yml`、`bifrost-api/app/config.py` 已统一使用 `BIFROST_` 前缀作为单一运行时契约。
  - `bifrost-api/app/main.py` 的 `/docs` / `/redoc` / `/openapi.json` 与 `bifrost-api/app/templates/register.html` 都已正确处理 `X-Forwarded-Prefix: /manage`。
  - 本轮集成合同测试时又额外发现并修复了 `register_page()` 对 `TemplateResponse` 的旧式参数顺序调用；该问题在当前 FastAPI/Starlette 依赖下会导致 `/register` 直接报错，现在已改为 `request=... / name=... / context=...` 的兼容写法。
- **验证**: 2026-03-26 合同测试已验证：
  - `/docs` 本地模式引用 `/openapi.json`
  - 带 `X-Forwarded-Prefix: /manage` 时引用 `/manage/openapi.json`
  - `/register` 会注入正确的 `data-api-prefix`
- **结论**: 运维文档、部署样例与运行时访问边界已恢复到同一真相。

### G5: 自动化验证链已覆盖 `bifrost-api` 管理面契约（已修复）

- **文件**: `tests/test-in-docker.sh`
- **修复**:
  - 新增 `test_bifrost_api_contracts()` 与 `bifrost` 测试入口。
  - 合同测试覆盖文档前缀、OpenAPI `servers`、注册页前缀注入、管理员鉴权 `401/403` 语义、默认 same-origin CORS。
  - 为避免把“宿主环境恰好装了 Python 依赖”误判为产品能力，测试现在支持本地缺依赖时按 `requirements.txt` 临时自举依赖后再执行。
  - 在把 `bifrost-api` 接入统一回归的过程中，又顺带修复了 3 个测试基线缺陷：`set -e` 下计数器提前退出、CLI 参数检查依赖过时源码扫描、Windows Git Bash + Docker 的路径转换导致容器测试假失败。
  - 当前 `docker` 套件还额外纳入了 `health-check.sh` 的 `bash -n`、`--help` 与 `health.json` smoke 产物校验，用于锁住本轮 live assurance 补审结果。
  - 最新一轮还修复了 Docker harness 的残留清理与前置失败可观测性：`aigw-test-*` 临时容器会在测试前后主动清理，`apt-get update/install` 这类准备步骤失败时会显式记为测试失败，而不再把 Git Bash `fork` / 资源错误隐藏成无摘要中断。
- **验证**:
  - `bash tests/test-in-docker.sh monitoring` 通过
  - `bash tests/test-in-docker.sh backup` 通过
  - `bash tests/test-in-docker.sh bifrost` 通过
  - `bash tests/test-in-docker.sh docker` 通过
  - `bash tests/test-in-docker.sh all` 通过，结果为 `166 通过, 0 失败, 0 跳过`
- **结论**: `bifrost-api` 已从“人工补审对象”升级为“统一回归矩阵中的一等公民”。

---

## 2026-03-27 第四轮补审更新（桥接副本漂移收口）

### G6: `ai-gateway-bridge/` 与 root `scripts/` 的安全修复漂移已收口（已修复）

- **问题性质**: 第三轮修掉的是 root `scripts/` 的真实漏洞，但 `ai-gateway-bridge/scripts/` 仍保留旧实现；这意味着仓库里同时存在“已修版”和“可重新引入旧漏洞的副本版”，属于典型补丁漂移。
- **修复文件**:
  - `ai-gateway-bridge/scripts/backup.sh`
  - `ai-gateway-bridge/scripts/uninstall.sh`
  - `ai-gateway-bridge/scripts/anti-dpi.sh`
  - `ai-gateway-bridge/scripts/monitoring.sh`
  - `ai-gateway-bridge/scripts/dd-reinstall.sh`
  - `ai-gateway-bridge/scripts/server-b.sh`
  - `ai-gateway-bridge/scripts/security.sh`
  - `ai-gateway-bridge/scripts/health-check.sh`
- **修复内容**:
  - `backup.sh` 同步 root 的 staging 打包模型，消除先压缩再追加 metadata 导致的归档覆盖/内容不确定性；同时修复首次生成 backup key 时 stdout 被日志污染，且保证 key 在收集备份路径前已创建，从而被纳入归档。
  - `uninstall.sh` 改为只删除精确的 AI Gateway Bridge cron marker / owned script path，并显式清理 `rkhunter` / `lynis` 系统 cron 文件，避免宽关键词误删用户任务。
  - `anti-dpi.sh`、`monitoring.sh`、`dd-reinstall.sh` 的 crontab 读写改成先读后改写的安全模式，不再依赖脆弱的 `crontab -l | grep -v ... | crontab -` 管道。
  - `monitoring.sh` 不再在缺失 `health-check.sh` 时偷偷落一个最小假检查脚本，而是直接 fail-fast；同时桥接副本的真实 `health-check.sh` 已恢复到仓库正确位置。
  - `server-b.sh` 去除第三方 `gitee` 的 `acme.sh curl | sh` fallback，并把 Caddy repo key 导入改成 fail-fast；port 80 的临时停服务逻辑也同步到“只接受受管服务，否则拒绝继续”。
  - `security.sh` 的 Lynis key 导入改为 fail-fast，不再吞掉 GPG 失败；Git fallback 也收敛回统一的 `github_clone_repo` 路径，避免硬编码第三方镜像行为。
- **新增验证**:
  - `tests/test-in-docker.sh` 新增桥接副本合同测试：
    - `test_bridge_monitoring_contracts()`
    - `test_bridge_backup_contracts()`
    - `test_bridge_uninstall_contracts()`
    - `test_bridge_supply_chain_contracts()`
  - 这些测试把 root 与桥接副本都纳入同一回归矩阵，防止未来再次出现“只修一套脚本”的漂移。
- **验证结果**:
  - `bash -n ai-gateway-bridge/scripts/backup.sh ai-gateway-bridge/scripts/uninstall.sh ai-gateway-bridge/scripts/anti-dpi.sh ai-gateway-bridge/scripts/monitoring.sh ai-gateway-bridge/scripts/dd-reinstall.sh ai-gateway-bridge/scripts/server-b.sh ai-gateway-bridge/scripts/security.sh ai-gateway-bridge/scripts/health-check.sh tests/test-in-docker.sh` 通过
  - `bash tests/test-in-docker.sh monitoring` 通过
  - `bash tests/test-in-docker.sh backup` 通过
  - `bash tests/test-in-docker.sh uninstall` 通过
  - `bash tests/test-in-docker.sh supply` 通过
  - `bash tests/test-in-docker.sh all` 通过，结果为 `172 通过, 0 失败, 1 跳过`
  - 唯一跳过项是 Docker 容器测试里的 `apt-get install`，原因是当前环境网络限制，不是脚本合同失败。
- **结论**: 本轮补审的关键盲区不是“新的单点漏洞”，而是“安全修复未在副本树同步”。该盲区现已闭合。

## 2026-03-27 第五轮补审更新（bridge helper 与 update 链路收口）

### G7: `ai-gateway-bridge/` 的共享 helper / update 链路仍存在旧实现漂移（已修复）

- **问题性质**: 第四轮之后继续深扫发现，桥接副本的 `common.sh` / `update.sh` / `mihomo.sh` 仍保留一批 root 已修掉的旧逻辑：
  - `common.sh` 被 `source` 时会无条件向 stdout 打 `common.sh loaded successfully.`，同时 `EXIT` trap 中旧版 `_spinner_stop()` 会在未启用 spinner 的情况下输出清屏控制字符，污染调用方 stdout。
  - `common.sh` 仍缺少 `github_fetch_text()` 与 `github_clone_repo()`；这让 `security.sh` 中对 `github_clone_repo` 的调用处于潜在运行期断链状态。
  - `update.sh` / `mihomo.sh` 仍各自手写 `curl + ghproxy.net` 分支，绕开 root 已统一的 GitHub helper 契约，导致镜像策略、错误提示和 stdout/stderr 语义再次漂移。
  - root 与 bridge 的 `update.sh` 都还在用拼接字符串 + `eval` 方式重建 Docker 容器，并把完整 `docker run ...` 命令写入日志；这会破坏带空格/特殊字符的环境变量与挂载参数，同时把敏感环境变量回显到日志。
- **修复文件**:
  - `ai-gateway-bridge/scripts/common.sh`
  - `scripts/update.sh`
  - `ai-gateway-bridge/scripts/update.sh`
  - `ai-gateway-bridge/scripts/mihomo.sh`
- **修复内容**:
  - bridge `common.sh` 已回迁 root 的 GitHub helper 契约：补齐 `github_mirror_prefixes()`、`github_mirror_help()`、`github_url_candidates()`、`github_fetch_text()`、`github_clone_repo()`，并让 `github_download_script()` 保持 stdout 纯净。
  - bridge `common.sh` 现已和 root 一样默认静默加载，仅在 `BIFROST_TRACE_COMMON_LOAD=1` 时输出加载日志；旧版 `_spinner_stop()` 的非交互 stdout 污染也已收敛。
  - bridge `common.sh` 的主日志路径已从 `/var/log/ai-gateway-bridge.log` 收敛到 `/var/log/ai-gateway-bridge/ai-gateway-bridge.log`，与现有 logrotate / health / diagnostics 目录策略对齐。
  - bridge `update.sh` / `mihomo.sh` 已改为统一使用 `github_fetch_text()`，不再硬编码 `ghproxy.net` 专属分支。
  - root 与 bridge `update.sh` 的容器手工重建逻辑已从字符串拼接 + `eval` 改为参数数组执行，同时停止回显完整 `docker run` 命令，避免参数破坏与敏感环境变量泄露。
- **新增验证**:
  - `tests/test-in-docker.sh` 新增 `update` 契约入口，并纳入 `all`：
    - root / bridge `update.sh` 不再使用 `eval` 重建容器，也不再日志回显完整 `docker run` 命令。
    - bridge `update.sh` / `mihomo.sh` 已收敛到共享 GitHub helper，不再硬编码 `ghproxy.net` 分支。
    - bridge `common.sh` 默认静默加载，且已补齐 `github_fetch_text()` / `github_clone_repo()`。

## 2026-03-27 第六轮补审更新（bridge server-b GitHub API 漂移收口）

### G8: `ai-gateway-bridge/scripts/server-b.sh` 的 Xray release 解析仍保留旧 `ghproxy` 分支（已修复）

- **问题性质**: 在第五轮之后做残留模式扫描时，仍发现 bridge `server-b.sh:_install_xray_manual()` 沿用“直接 curl GitHub API，失败后手写 `ghproxy.net/${api_url}`”的旧版本查询逻辑，没有收敛到共享 `github_fetch_text()` helper。
- **风险**:
  - bridge 副本继续绕开统一的镜像覆盖契约，导致 `BIFROST_GITHUB_MIRROR_PREFIXES` 无法覆盖该链路。
  - `server-b.sh` 与 `common.sh` / `update.sh` / `mihomo.sh` 的 GitHub 访问语义再次分叉，后续维护容易重新引入硬编码第三方镜像依赖。
- **修复文件**:
  - `ai-gateway-bridge/scripts/server-b.sh`
- **修复内容**:
  - `_install_xray_manual()` 已改为通过 `github_fetch_text "${api_url}" 20 10` 获取 release 元数据，并同步把日志文案收敛为“configured mirrors”语义。
- **新增验证**:
  - `tests/test-in-docker.sh` 的桥接 `supply` 套件已新增合同检查，锁定：
    - bridge `server-b.sh` 使用共享 `github_fetch_text()` 获取 Xray 最新版本
    - 该路径不再保留 `ghproxy.net/${api_url}` 硬编码分支

## 2026-03-27 第七轮补审更新（Mihomo 节点注入边界收紧）

### G9: `add_mihomo_node()` 会把未校验的用户输入直接插入 `yq/sed/YAML`（已修复）

- **问题性质**: root 与 bridge 的 `mihomo.sh:add_mihomo_node()` 之前只校验端口，不校验 `node_name` 与 `node_addr`。这两个值会被直接插入：
  - `yq -i` 表达式
  - `sed -i` fallback 脚本
  - YAML `proxy` 配置块
- **风险**:
  - 带引号、反斜杠、空格或换行的输入会破坏 `yq/sed` 表达式，导致配置写坏或节点插入失败。
  - 重复节点检测使用 `grep -q "name: \"${node_name}\""`，在未校验输入下也会受到正则元字符干扰。
  - 该问题在 root 与 bridge 两棵树同时存在，属于共享配置编辑面上的输入注入/破坏风险。
- **修复文件**:
  - `scripts/mihomo.sh`
  - `ai-gateway-bridge/scripts/mihomo.sh`
- **修复内容**:
  - `add_mihomo_node()` 现已在端口校验前新增 `node_name` / `node_addr` 白名单校验，仅允许字母、数字、点、下划线、冒号和连字符。
  - 对不安全输入会在任何文件编辑、副作用、依赖安装前直接 fail-fast。
- **新增验证**:
  - `tests/test-in-docker.sh` 新增 `mihomo` 契约入口，并纳入 `all`：
    - root `add_mihomo_node()` 会拒绝危险名称/地址
    - bridge `add_mihomo_node()` 会拒绝危险名称/地址

## 2026-03-27 第八轮补审更新（Xray geodata 首装 fail-open 收口）

### G10: `server-a` 在缺失 `geoip.dat/geosite.dat` 且下载失败时仍会继续部署（已修复）

- **问题性质**: root 与 bridge 的 `server-a.sh:_ensure_xray_geodata()` 之前在 geodata 缺失且下载失败时只打印 `warn` 后继续执行；但同一脚本生成的 Xray 路由配置明确使用了 `geosite:cn` / `geosite:private` / `geoip:cn` / `geoip:private`。
- **风险**:
  - 首次部署环境里，如果 geodata 资源无法下载，脚本会继续生成依赖这些规则的数据平面配置，形成“安装流程看似完成，但 Xray 路由依赖未满足”的假成功状态。
  - Xray 官方路由文档将 `geosite:*` / `geoip:*` 建立在 `geosite.dat` / `geoip.dat` 资源文件之上；缺失资源时，对应规则不再是可选能力，而是启动前依赖。[Project X Routing, https://xtls.github.io/config/routing.html]
  - 公开 issue 里也有 geodata 缺失后 Xray 启动报错的实际案例，说明这不是理论风险。[3x-ui issue #3074, https://github.com/MHSanaei/3x-ui/issues/3074]
- **修复文件**:
  - `scripts/server-a.sh`
  - `ai-gateway-bridge/scripts/server-a.sh`
- **修复内容**:
  - `_ensure_xray_geodata()` 现在对 `geoip.dat` / `geosite.dat` 使用 `-s` 校验，不再把空文件当成成功。
  - 下载改为先落临时文件，再原子替换到目标路径。
  - 任一 geodata 资源缺失且下载失败时立即 `log_error + return 1`，拒绝继续进入后续配置生成。
- **新增验证**:
  - `tests/test-in-docker.sh` 新增 `xray` 契约入口，并纳入 `all`：
    - root `server-a` 在缺失 geodata 且下载失败时会 fail-fast
    - bridge `server-a` 在缺失 geodata 且下载失败时会 fail-fast

## 2026-03-27 第九轮补审更新（update 盲重装与 Mihomo YAML 回退收口）

### G11: `update.sh` 在拿不到 release 元数据时仍允许盲重装（已修复）

- **问题性质**: root 与 bridge 的 `update.sh:update_xray()/update_mihomo()` 之前在 `_get_github_latest_version()` 返回空值时，只打印 `Could not determine latest ... version`，随后继续询问 `Proceed with reinstall anyway?`。这会让“安全更新”退化成无目标版本、无可验证 upgrade target 的盲重装。
- **风险**:
  - 当 GitHub API / 镜像链路失效时，脚本仍可能继续下载并执行安装逻辑，失去“当前版本 -> 目标版本”的可验证闭环。
  - 成功日志此前只显示 `updated: old -> new`，如果安装脚本返回成功但最终版本并未达到预期 tag，运维侧会得到误导性的正向反馈。
  - 该问题同时存在于 root 与 bridge 两棵树，属于共享更新面上的 fail-open。
- **修复文件**:
  - `scripts/update.sh`
  - `ai-gateway-bridge/scripts/update.sh`
- **修复内容**:
  - 当无法解析最新 Xray / Mihomo release tag 时，更新流程现在直接 `log_error + return 1`，拒绝任何 blind reinstall。
  - 更新完成后新增版本核验：若最终版本为空、`unknown`、`not_installed`，或不等于预期 `latest_ver`，则明确报错并拒绝输出成功结论。
- **新增验证**:
  - `tests/test-in-docker.sh` 的 `update` 套件已扩展并纳入 `all`：
    - root `update.sh` 在 release 元数据缺失时会拒绝盲重装
    - bridge `update.sh` 在 release 元数据缺失时会拒绝盲重装

### G12: `add_mihomo_node()` 在缺失 `yq` 时仍回退到 `sed` 改写 YAML（已修复）

- **问题性质**: root 与 bridge 的 `mihomo.sh:add_mihomo_node()` 之前即使没有 `yq`，仍会退化到 `sed` 方式直接修改 `config.yaml`，并仅以 `less reliable` 警告继续执行。
- **风险**:
  - Mihomo 配置是实际流量分流与故障转移的控制面，`sed` 对 YAML 结构没有语义感知，容易因分组顺序、缩进或模板变化写坏配置。
  - 这种“先写 live config，再靠后置校验补救”的策略，会让缺依赖环境表现成“脚本还能继续跑”，但确定性已经丢失。
  - 即使前一轮已经收紧了 `node_name/node_addr` 输入边界，只要继续允许 `sed` 回退，结构性破坏风险仍然存在。
- **修复文件**:
  - `scripts/mihomo.sh`
  - `ai-gateway-bridge/scripts/mihomo.sh`
- **修复内容**:
  - `add_mihomo_node()` 现在把 `yq` 视为安全编辑的硬依赖；缺失时立即 `log_error + return 1`，不再允许 `sed` fallback。
  - 三处 `yq -i` 写入步骤均已加上失败回滚：任一步骤失败都会恢复备份配置并退出。
- **新增验证**:
  - `tests/test-in-docker.sh` 的 `mihomo` 套件已扩展并纳入 `all`：
    - root `add_mihomo_node()` 在缺失 `yq` 时会 fail-fast
    - bridge `add_mihomo_node()` 在缺失 `yq` 时会 fail-fast

- **本轮回归结果**:
  - `bash tests/test-in-docker.sh update` → `6 通过, 0 失败, 0 跳过`
  - `bash tests/test-in-docker.sh mihomo` → `4 通过, 0 失败, 0 跳过`
  - `bash tests/test-in-docker.sh all` → `200 通过, 0 失败, 0 跳过`

## 2026-03-27 第十轮补审更新（Server B 3x-ui 面板配置假成功收口）

### G13: `server-b` 的 3x-ui 面板配置链路会吞掉 CLI / sqlite 失败并继续报完成（已修复）

- **问题性质**:
  - root `scripts/server-b.sh:_configure_3xui_panel()` 虽然已经具备“CLI 优先 + sqlite legacy fallback”的结构，但 legacy sqlite 分支仍对两条 `sqlite3 UPDATE` 使用 `|| true`，即使更新失败也继续打印 `Panel settings updated via legacy database fallback.`。
  - bridge `ai-gateway-bridge/scripts/server-b.sh` 更旧：没有共享 `_configure_3xui_panel()` helper，`sqlite3` 与 `x-ui setting` 两条路径都直接吞错，随后安装主流程仍继续打印面板 URL / 用户名 / 密码，形成更明显的假成功。
- **风险**:
  - 当 `x-ui setting` 不可用、数据库 schema 变化、`sqlite3` 不存在或执行失败时，脚本仍可能输出一组“看似已生效”的管理面凭据，误导用户以为端口和密码已经被写入。
  - 这属于控制面的高风险可观测性问题：失败没有被显式暴露，后续排障会直接偏离真实根因。
  - root 与 bridge 两棵树行为不一致，说明共享 runbook 已再次发生 drift。
- **修复文件**:
  - `scripts/server-b.sh`
  - `ai-gateway-bridge/scripts/server-b.sh`
  - `tests/test-in-docker.sh`
- **修复内容**:
  - root `_configure_3xui_panel()` 现在只会在两条 `sqlite3 UPDATE` 都成功时才宣告 legacy fallback 成功；否则明确记录 fallback 失败并返回非 0。
  - bridge 已回迁同一套 `_configure_3xui_panel()` helper，并改为和 root 一样由主流程显式处理返回值，不再在 `sqlite3` / `x-ui` 调用上吞错。
  - 主流程仍可继续部署，但会明确告诉操作者“Panel may need manual configuration after first login”，不再把失败包装成“配置已完成”。
- **新增验证**:
  - `tests/test-in-docker.sh` 新增 `panel` 套件，并纳入 `all`：
    - root `server-b` 在 `x-ui CLI` 与 `sqlite` fallback 同时失败时会显式报错
    - bridge `server-b` 在 `x-ui CLI` 与 `sqlite` fallback 同时失败时会显式报错
- **本轮回归结果**:
  - `bash tests/test-in-docker.sh panel` → `2 通过, 0 失败, 0 跳过`
  - `bash tests/test-in-docker.sh all` → `202 通过, 0 失败, 0 跳过`

## 2026-03-27 第十一轮补审更新（Mihomo geodata 首装 fail-open 收口）

### G14: `_mihomo_download_geodata()` 在缓存不存在时下载失败仍会继续部署（已修复）

- **问题性质**: root 与 bridge 的 `mihomo.sh:_mihomo_download_geodata()` 之前对 `geoip.dat` / `geosite.dat` / `country.mmdb` / `GeoLite2-ASN.mmdb` 一律采用“下载失败就 `warn`，继续使用 cached data”逻辑；但在首次部署、缓存为空或文件大小为 0 的情况下，这个文案并不成立，因为根本没有 cached data 可退。
- **风险**:
  - `configs/mihomo/config.yaml.tpl` 已开启 `geodata-mode: true`，并且当前规则直接使用 `geosite:cn,private`、`geosite:geolocation-!cn`、`GEOIP,CN`、`GEOIP,private`。当 `geoip.dat/geosite.dat` 不存在时，继续安装会把控制面推进到一个依赖未满足的状态。
  - 这会形成和先前 Xray geodata 问题同类的“首装看似完成，实际路由数据平面不完整”的假成功。
  - root 与 bridge 两棵树同时存在该问题，说明 geodata 依赖契约此前只在 Xray 链路上收紧，Mihomo 链路仍有同型漏口。
- **修复文件**:
  - `scripts/mihomo.sh`
  - `ai-gateway-bridge/scripts/mihomo.sh`
  - `tests/test-in-docker.sh`
- **修复内容**:
  - `_mihomo_download_geodata()` 现在对 geodata 文件使用 `-s` 语义：文件缺失或为空时，视为必须完成 fresh download。
  - 下载改为先落临时文件，再原子 `mv` 到目标路径，避免把空文件或半下载文件写成“成功缓存”。
  - 若缓存存在但刷新失败，仍允许警告后继续使用旧缓存；若缓存不存在且下载失败，则立即 `log_error + return 1`，拒绝继续部署。
- **新增验证**:
  - `tests/test-in-docker.sh` 的 `mihomo` 套件已扩展并纳入 `all`：
    - root `mihomo` 在 geodata 首装下载失败时会 fail-fast
    - bridge `mihomo` 在 geodata 首装下载失败时会 fail-fast
- **本轮回归结果**:
  - `bash tests/test-in-docker.sh mihomo` → `6 通过, 0 失败, 0 跳过`
  - `bash tests/test-in-docker.sh all` → `204 通过, 0 失败, 0 跳过`

## 2026-03-27 第十二轮补审更新（Keepalive 控制面假成功收口）

### G15: `keepalive.sh` 在 Xray 配置缺失/损坏时仍会打印完成摘要（已修复）

- **问题性质**:
  - root 与 bridge 的 `setup_xray_keepalive()` 之前在 `XRAY_CONFIG` 缺失或 JSON 非法时，只做 `warn/skip` 级处理；随后 `deploy_keepalive()` 仍继续执行 heartbeat / watchdog，并最终输出 `Keepalive Deployment Complete` 与 `[OK] Xray sockopt: keepalive injected into config`。
  - 这不是单纯的容错，而是控制面假成功：真实未完成的 Xray `sockopt` 注入被包装成了“保活已部署”。
- **风险**:
  - `keepalive.sh` 直接承载连接保活、NAT 映射维持与 watchdog 链路，和“规避国内探测导致的静默掉线”高度相关。若 Xray 配置没有真实打补丁，后续 heartbeat / watchdog 即使存在，也无法弥补真正的传输层参数缺口。
  - 操作者会被完成摘要误导，排障时优先怀疑心跳或 watchdog，而不是回到最前面的 Xray 配置缺失/损坏根因。
  - root 与 bridge 同时存在，说明这一类“前置依赖失败但部署摘要继续完成”的模式此前仍未被完全清扫。
- **修复文件**:
  - `scripts/keepalive.sh`
  - `ai-gateway-bridge/scripts/keepalive.sh`
  - `tests/test-in-docker.sh`
- **修复内容**:
  - `setup_xray_keepalive()` 现在对两类前置条件都改为硬失败：`XRAY_CONFIG` 不存在时直接 `log_error + return 1`，JSON 非法时也拒绝继续 patch。
  - `deploy_keepalive()` 现在对 `setup_tcp_keepalive` / `setup_xray_keepalive` / `setup_heartbeat_service` / `setup_watchdog` 全链路使用 `|| return 1`，任何一步失败都不会再进入完成摘要。
- **新增验证**:
  - `tests/test-in-docker.sh` 新增 `keepalive` 套件，并纳入 `all`：
    - root `keepalive` 在缺失 Xray config 时会终止且不打印完成摘要
    - root `keepalive` 在 Xray config 非法 JSON 时会终止且不打印完成摘要
    - bridge `keepalive` 在缺失 Xray config 时会终止且不打印完成摘要
    - bridge `keepalive` 在 Xray config 非法 JSON 时会终止且不打印完成摘要
- **本轮回归结果**:
  - `bash tests/test-in-docker.sh keepalive` → `4 通过, 0 失败, 0 跳过`
  - `bash tests/test-in-docker.sh all` → `211 通过, 0 失败, 1 跳过`

## 2026-03-27 第十三轮补审更新（Multi-server 与 Mihomo 路由同步原子性收口）

### G16: `multi-server.sh` 会在 Mihomo 未接入时假称“已加入 proxy pool”，且移除最后节点后会残留 stale pool（已修复）

- **问题性质**:
  - root 与 bridge 的 `_update_mihomo_config()` 之前在找不到 `MIHOMO_CONFIG` / `MIHOMO_FALLBACK_CONFIG` 时仅 `warn + return 0`，而 `add_server_b()` 在写入 `servers.conf` 后无条件继续打印 `Server '<name>' added to the proxy pool.`。
  - 同一函数在注册表为空时也直接 `return 0`，不会移除 Mihomo 配置里旧的 managed proxy section。这意味着“移除最后一个节点”后，路由引擎里仍可能残留过期的 `ServerB-Pool`。
- **风险**:
  - 节点控制面会出现明显错觉：注册表里有节点，但 Mihomo 根本没接入；或者注册表已空，但 Mihomo 还留着陈旧的故障转移池。
  - 这直接破坏多节点负载均衡 / 故障转移的真实性，属于用户第 5 条“mihomo 路由引擎衔接正确”上的高优先级缺口。
  - 若配置写入后重启 Mihomo 失败，旧实现也只会打印警告，不会回滚已写入状态，继续扩大“脚本说成功、路由面并未成功”的偏差。
- **修复文件**:
  - `scripts/multi-server.sh`
  - `ai-gateway-bridge/scripts/multi-server.sh`
  - `tests/test-in-docker.sh`
- **修复内容**:
  - `_update_mihomo_config()` 现在把“找不到 Mihomo/Clash 配置”视为硬失败，不再允许 route-engine 缺失时返回成功。
  - 当注册表已空时，脚本会主动移除 Mihomo managed proxy pool section，而不是保留 stale 节点。
  - `add_server_b()` / `remove_server_b()` 现在把“注册表改动 + Mihomo 同步”视为一个原子操作：路由同步失败时会回滚注册表，避免留下半成功状态。
  - Mihomo/Clash 在配置更新后的重载失败现在也会触发配置恢复，不再只记一条 warning 就继续。
- **新增验证**:
  - `tests/test-in-docker.sh` 新增 `multi` 套件，并纳入 `all`：
    - root `multi-server` 在缺失 Mihomo 配置时会回滚注册表且不宣称已入池
    - root `multi-server` 在注册表清空后会移除 Mihomo managed proxy pool
    - bridge `multi-server` 在缺失 Mihomo 配置时会回滚注册表且不宣称已入池
    - bridge `multi-server` 在注册表清空后会移除 Mihomo managed proxy pool
- **本轮回归结果**:
  - `bash tests/test-in-docker.sh multi` → `4 通过, 0 失败, 0 跳过`
  - `bash tests/test-in-docker.sh all` → `211 通过, 0 失败, 1 跳过`

## 2026-03-27 第十四轮补审更新（User-management 交付原子性收口）

### G17: `user-management.sh` 会在 VPN/API 未真实建成时仍登记本地用户并打印成功（已修复）

- **问题性质**:
  - root 与 bridge 的 `create_user()` 之前把 `_add_xray_user()` 与 `_create_api_token()` 都当成 best-effort：即使 Xray 注入失败、New API token 创建失败，脚本仍会继续写 `registry.conf`、输出 `.credentials`、生成 onboarding guide，并打印 `User '<name>' Created Successfully`。
  - 在启用了企业 VPN 的环境里，`create_vpn_user` 缺失、`vpn.sh` 不存在、或 WireGuard 配置未真实生成时，旧实现也只是打印 `pending / create manually`，没有把它视为交付失败。
- **风险**:
  - 这会把“本地台账已写入”伪装成“用户凭据已交付”，而规格书与使用文档都把该模块定义为 `VPN 凭据 + API Token + 入职指南` 的完整链路，不是占位登记器。
  - 一旦管理员把 guide/credentials 发给员工，员工会拿到一份本地看起来存在、但真实不可用的账户材料，导致排障直接偏离根因。
  - 这类问题和前面 keepalive/multi-server 的假成功属于同一家族：数据面/控制面未完成，本地摘要却提前宣告成功。
- **修复文件**:
  - `scripts/user-management.sh`
  - `ai-gateway-bridge/scripts/user-management.sh`
  - `tests/test-in-docker.sh`
- **修复内容**:
  - `create_user()` 现在把 Xray 注入失败视为硬失败，不再继续进入 registry/guide/credentials 落盘。
  - 当企业 VPN 已部署时，若 `create_vpn_user` 不存在、`vpn.sh` 缺失，或 WireGuard 客户端配置未真实生成，脚本会直接中止，而不是把 WireGuard 状态标成 `pending`。
  - New API token 创建失败时，脚本现在会执行 best-effort rollback：撤销已写入的 Xray 用户，并在可用时回滚 WireGuard peer，不再留下半成功访问状态。
  - 本地 `registry.conf`、`.credentials`、onboarding guide 仅在完整交付成功后才会写入，成功摘要不再覆盖真实失败。
- **新增验证**:
  - `tests/test-in-docker.sh` 新增 `user` 套件，并纳入 `all`：
    - root `user-management` 在 Xray 失败时不会登记本地用户或打印成功
    - root `user-management` 在 API token 失败时会回滚 Xray 并拒绝落本地状态
    - bridge `user-management` 在 Xray 失败时不会登记本地用户或打印成功
    - bridge `user-management` 在 API token 失败时会回滚 Xray 并拒绝落本地状态
- **本轮回归结果**:
  - `bash tests/test-in-docker.sh user` → `4 通过, 0 失败, 0 跳过`
  - `bash tests/test-in-docker.sh all` → `216 通过, 0 失败, 0 跳过`

## 2026-03-27 第十五轮补审更新（User-management 禁用/撤销链路镜像收口）

### G18: `disable_user()` 会在真实撤销失败时仍写 `disabled`，且此前遗漏 WireGuard 撤销（已修复）

- **问题性质**:
  - root 与 bridge 的 `disable_user()` 之前无条件调用 `_remove_xray_user`，随后即使 API token disable 失败也只记 warning，然后直接把 `registry.conf` 状态写成 `disabled`。
  - 更严重的是，这条链路此前根本没有触及 `revoke_vpn_user`，也就是创建阶段如果发过 WireGuard 配置，禁用阶段却可能完全不撤销 WireGuard 访问。
  - `_remove_xray_user()` 旧实现本身也存在 fail-open：Xray 配置缺失时直接返回 0，JSON 修改失败只打 warning，不阻止上层把用户标成已禁用。
- **风险**:
  - 这会制造“本地台账 disabled，但 Xray/WireGuard/API 任一访问仍存活”的镜像假成功，和创建链路的问题完全对称。
  - 对管理员来说，这种状态最危险，因为看上去已经完成离职/封禁，实际上用户仍可能保留一条或多条有效访问路径。
  - WireGuard 撤销遗漏意味着用户第 2、5、6 条里强调的零信任、路由入口与探测规避都会被本地台账假象掩盖。
- **修复文件**:
  - `scripts/user-management.sh`
  - `ai-gateway-bridge/scripts/user-management.sh`
  - `tests/test-in-docker.sh`
- **修复内容**:
  - `_remove_xray_user()` 现在把“Xray config 缺失 / JSON 删除失败 / 重启失败”都视为真实失败，不再 fail-open。
  - `_disable_api_token()` 现在要求禁用/删除结果可验证，不能再把“收到任意响应”当作成功。
  - 新增 `_force_revoke_vpn_user()`，在非交互路径下自动确认并执行 `revoke_vpn_user`，使 `disable_user()` 与创建链路在 WireGuard 维度上闭环对称。
  - `disable_user()` 现在把 Xray、WireGuard、API 三条撤销链路聚合判断；任一关键撤销失败，都不会更新本地 registry 为 `disabled`。
- **新增验证**:
  - `tests/test-in-docker.sh` 的 `user` 套件已扩展并纳入 `all`：
    - root `user-management` 在撤销 Xray 失败时不会把本地状态写成 `disabled`
    - root `user-management` 在 WireGuard 撤销失败时不会写 `disabled`，且会实际触发撤销路径
    - bridge `user-management` 在撤销 Xray 失败时不会把本地状态写成 `disabled`
    - bridge `user-management` 在 WireGuard 撤销失败时不会写 `disabled`，且会实际触发撤销路径
- **本轮回归结果**:
  - `bash tests/test-in-docker.sh user` → `8 通过, 0 失败, 0 跳过`
  - `bash tests/test-in-docker.sh all` → `220 通过, 0 失败, 0 跳过`

## 2026-03-27 第十六轮补审更新（Whitelist 控制面原子性收口）

### G19: `whitelist.sh` 会在 Xray 路由未真实同步时仍改本地白名单，且删除子域名时可能遗留 `domain:<base>` 路由（已修复）

- **问题性质**:
  - root 与 bridge 的 `add_domain()` / `remove_domain()` 之前都先改 `ai-domains.txt`，再调用 `_update_xray_routing()`；如果 Xray 配置不存在、`jq` 缺失、或 JSON 写回失败，脚本仍会保留本地白名单变更，并打印 `added to whitelist` / `removed from whitelist` 一类成功信息。
  - `_update_xray_routing()` 自身此前是 fail-open：`jq` 缺失和 Xray config 缺失都直接 `return 0`，把“没有任何 route-engine 同步”伪装成成功。
  - 删除链路还有一个更隐蔽的逻辑错误：新增 `api.openai.com` 时，脚本实际写入的是标准化后的 `domain:openai.com`；但删除时却按原始子域名模糊匹配，可能导致 whitelist 已删除而 Xray 路由残留。
- **风险**:
  - 这会制造“控制面白名单已变更，数据面 Xray 路由仍旧状态”的经典漂移，和前面的 `multi-server` / `user-management` 属于同一家族问题。
  - 更糟的是，子域名删除残留意味着管理员以为某个 AI 供应商入口已经被收口，实际上 `domain:<base>` 规则仍在生效，流量还能继续穿过既有入口。
  - 这类偏差会直接污染后续对零信任入口、流量管控与出口审计的判断，因为运维看到的是“文件已改”，不是“真实路由面已收敛”。
- **修复文件**:
  - `scripts/whitelist.sh`
  - `ai-gateway-bridge/scripts/whitelist.sh`
  - `tests/test-in-docker.sh`
- **修复内容**:
  - 新增 staged/backup 机制，`add_domain()` / `remove_domain()` 现在把“本地白名单写入 + Xray 路由同步”视为一个事务；任一路由同步失败，都会恢复 whitelist 文件，不再留下半成功状态。
  - `_update_xray_routing()` 现在把 `jq` 缺失、Xray config 缺失、以及 jq 写回失败都视为硬失败，不再 fail-open。
  - 删除路由时引入统一的 `domain:<base>` 归一化规则，确保 `api.openai.com` 这类子域名删除会准确移除 `domain:openai.com` 对应的 Xray 规则。
  - `remove_domain()` 现在还会同步清理紧邻该域名的自动注释行，避免手工添加记录在回滚/删除后继续漂浮。
  - 成功日志延后到真实路由同步之后，不再提前宣告 whitelist 已更新。
- **新增验证**:
  - `tests/test-in-docker.sh` 新增 `whitelist` 套件，并纳入 `all`：
    - root `whitelist` 在 Xray 配置缺失时会回滚新增域名且不打印成功
    - root `whitelist` 在 Xray 配置缺失时不会删除本地域名或打印移除成功
    - root `whitelist` 删除子域名时会同步移除归一化后的 Xray 路由规则
    - bridge `whitelist` 在 Xray 配置缺失时会回滚新增域名且不打印成功
    - bridge `whitelist` 在 Xray 配置缺失时不会删除本地域名或打印移除成功
    - bridge `whitelist` 删除子域名时会同步移除归一化后的 Xray 路由规则
- **本轮回归结果**:
  - `bash tests/test-in-docker.sh whitelist` → `6 通过, 0 失败, 0 跳过`
  - `bash tests/test-in-docker.sh all` → `226 通过, 0 失败, 0 跳过`

## 2026-03-27 第十七轮补审更新（Bifrost API 管理面假成功收口）

### G20: `bifrost-api.sh` 会在服务未健康/未卸载时仍打印完成摘要或成功状态（已修复）

- **问题性质**:
  - `deploy_bifrost_api()` 之前在 `docker compose up -d` 之后，只要容器启动命令本身返回 0，就会在健康检查超时后继续打印 `Deployment Complete` 摘要、管理地址与 admin key。
  - `_ba_restart()` 之前也把“compose restart 已执行”与“服务已健康”混在一起：健康检查超时只打一条 warning，不向上层返回失败。
  - `_ba_uninstall()` 之前的容器删除链路尾部带 `|| true`，这意味着即使 `docker compose down` 和 `docker rm -f` 都失败，函数仍会继续打印 `Container removed.` 和 `Bifrost API uninstalled.`。
- **风险**:
  - 这会把“容器命令已发出”伪装成“管理平台已可用”，管理员会拿着尚不可访问的 `/manage/docs`、`/manage/register` 和 admin key 继续下一步联调，直接污染排障方向。
  - 卸载链路的假成功更危险，因为它会制造“服务已下线”的错觉，而真实容器仍可能驻留并继续暴露管理面。
  - 这和前面 `keepalive`、`user-management`、`whitelist` 的本质一致：控制面摘要领先于真实状态验证。
- **修复文件**:
  - `scripts/bifrost-api.sh`
  - `tests/test-in-docker.sh`
- **修复内容**:
  - `deploy_bifrost_api()` 现在把健康检查视为发布完成的必要条件；超时会直接返回失败，不再打印部署完成摘要或暴露成功态访问信息。
  - `_ba_restart()` 现在要求 `docker compose restart` 与后续健康检查都成功，否则返回非零，不再把“重启已触发”当作“重启成功”。
  - `_ba_uninstall()` 现在要求容器删除可验证成功；若 `down/rm` 失败或容器仍存在，会直接报错并终止，不再继续输出 `uninstalled`。
  - 当管理员选择删除 `.env` 时，脚本也会验证配置文件删除结果，避免再出现“删失败但继续宣告完成”的尾部假成功。
- **新增验证**:
  - `tests/test-in-docker.sh` 的 `bifrost` 套件已扩展并纳入 `all`：
    - `bifrost-api deploy` 在健康检查超时时不会打印完成摘要
    - `bifrost-api restart` 在健康检查超时时会返回失败
    - `bifrost-api uninstall` 在容器删除失败时不会打印已卸载
- **本轮回归结果**:
  - `bash tests/test-in-docker.sh bifrost` → `4 通过, 0 失败, 0 跳过`
  - `bash tests/test-in-docker.sh all` → `229 通过, 0 失败, 0 跳过`

## 2026-03-27 第十八轮补审更新（Backup rotate-ip 控制面假成功收口）

### G21: `backup.sh` 的 `emergency_ip_rotation()` 会在零变更或 tunnel 未验证时仍宣告完成（已修复）

- **问题性质**:
  - root 与 bridge 的 `emergency_ip_rotation()` 之前都会在连通性测试之前打印 `IP rotation complete. Updated ... config(s).`。这意味着“配置文件已被修改”会被直接包装成“IP rotation 已完成”，而不是等待 tunnel 真正可用。
  - 更严重的是，当 `curl --proxy socks5://127.0.0.1:10808` 连通性检查失败时，函数只打一条 `The tunnel may need time to establish.` warning，然后整体仍以成功路径结束。
  - 另一条隐藏得更深的路径是 `changes_made == 0`：如果 Xray/Mihomo/Server B connection file 都没被真实更新，脚本此前仍会继续进入重启/验证段，最后以 warning 收口，而不是明确判定“本次 rotate-ip 没有产生任何有效变更”。
- **风险**:
  - 这会把“本地配置已改写”伪装成“入口切换已经完成”，而管理员最关心的真实问题恰恰是：新 IP 下的 tunnel 是否已恢复可用、Mihomo/Xray 是否已恢复到可转发状态。
  - 如果连通性失败但脚本仍打印完成，后续排障会被强行推到错误方向：操作者会优先怀疑上游厂商、证书、DPI 或用户侧环境，而不是回头检查 rotate-ip 本身是否真实收口。
  - `changes_made == 0` 还能制造另一种静默漂移：控制面看似执行过切换，实际上没有任何关键配置承载这次变更，属于典型的“命令已跑，但交付物为空”的假成功。
- **修复文件**:
  - `scripts/backup.sh`
  - `ai-gateway-bridge/scripts/backup.sh`
  - `tests/test-in-docker.sh`
- **修复内容**:
  - `emergency_ip_rotation()` 现在复用既有 `XRAY_CONFIG_DIR` / `MIHOMO_CONFIG_DIR` 常量解析配置路径，避免函数内部再硬编码另一套文件定位规则。
  - 当 `changes_made <= 0` 时，函数现在立即 fail-fast 并返回非零，不再继续重启服务或打印完成摘要。
  - 成功摘要被延后到“服务重启成功 + quick connectivity test 通过”之后；只有 tunnel 真正验证通过，才会打印 `IP rotation complete`。
  - 当 quick connectivity test 失败时，函数现在会明确报错、保留手工检查与回滚指引，并返回非零，而不是 warning 后继续假成功收口。
- **新增验证**:
  - `tests/test-in-docker.sh` 的 `backup` 套件已扩展并纳入 `all`：
    - root `backup rotate-ip` 在零变更时会 fail-fast，且不会打印完成摘要
    - root `backup rotate-ip` 在 tunnel 验证失败时会返回失败，且不会打印完成摘要
    - bridge `backup rotate-ip` 在零变更时会 fail-fast，且不会打印完成摘要
    - bridge `backup rotate-ip` 在 tunnel 验证失败时会返回失败，且不会打印完成摘要
- **本轮回归结果**:
  - `bash tests/test-in-docker.sh backup` → `12 通过, 0 失败, 0 跳过`
  - `bash tests/test-in-docker.sh all` → `233 通过, 0 失败, 0 跳过`

## 2026-03-27 第十九轮补审更新（Diagnostics 报告导出真实性收口）

### G22: `diagnostics.sh` 会在 JSON 报告无效或默认目录不可写时仍制造“报告已保存”错觉（已修复）

- **问题性质**:
  - root 与 bridge 的 `generate_diagnostic_report()` 之前都在手工拼接 JSON，但只有 `system` 段做了最基础的值转义；`services`、`network`、`dns`、`speed`、`gfw_detection` 的值一旦包含引号、反斜杠或换行，最终 payload 就可能变成非法 JSON。
  - 更关键的是，旧逻辑在 `jq` pretty-print 失败后会直接把原始字符串 `echo` 到文件里，然后继续打印 `Diagnostic report saved.`。也就是说，哪怕导出的其实是坏 JSON，脚本仍会把它包装成成功交付。
  - bridge 版本还比 root 少了一层 writable report dir fallback，默认假定 `/var/log/ai-gateway-bridge` 可写；这让本地验证或低权限执行时更容易在目录阶段失败，且与 root 版本的行为继续漂移。
  - 同时，两边的诊断结果数组在多次执行之间不会主动清空，存在把上一轮残留观测带进新报告的风险。
- **风险**:
  - 管理员拿到“已保存”的报告路径后，通常会把它当作排障事实源。如果文件其实不是合法 JSON，或者混入了上一轮残留数据，后续自动分析、告警收集、审计归档都会建立在坏证据之上。
  - 这类问题比普通 warning 更隐蔽，因为操作者不是看终端摘要，而是信任导出的 artifact；一旦 artifact 本身是坏的，就会把错误扩散到教程、runbook、二次分析脚本和人工判断。
  - bridge 与 root 的目录解析不一致，还会让“同一份诊断命令在两棵树上行为不同”这种环境漂移继续扩大。
- **修复文件**:
  - `scripts/diagnostics.sh`
  - `ai-gateway-bridge/scripts/diagnostics.sh`
  - `tests/test-in-docker.sh`
- **修复内容**:
  - 为两边的 diagnostics 报告导出统一补上 JSON 值转义与 section 渲染 helper，不再只对 `system` 段做半套转义。
  - 报告写盘现在必须经过真实校验：`jq` 可用时要求渲染结果能被解析；写盘失败、空文件、`chmod` 失败、`latest` link 更新失败都会直接返回非零，不再假装 `saved`。
  - bridge 版本补齐与 root 对齐的 writable report dir fallback，并统一支持通过 `TMPDIR`/可写临时目录落盘，保证低权限/本地验证路径不会继续和 root 分叉。
  - `run_full_diagnostic()` 现在在每次执行前都会重置诊断结果数组，避免上一轮观测残留污染新报告。
- **新增验证**:
  - `tests/test-in-docker.sh` 新增 `diagnostics` 套件，并纳入 `all`：
    - root diagnostics report 在默认目录不可写时会回退到临时目录，并输出可解析 JSON
    - bridge diagnostics report 在默认目录不可写时会回退到临时目录，并输出可解析 JSON
    - 两条合同都显式注入包含引号、反斜杠、换行的值，证明报告导出不再把坏 JSON 伪装成成功
- **本轮回归结果**:
  - `bash tests/test-in-docker.sh diagnostics` → `2 通过, 0 失败, 0 跳过`
  - `bash tests/test-in-docker.sh all` → `235 通过, 0 失败, 0 跳过`

## 2026-03-27 第二十轮补审更新（主部署流假成功与入口吞错收口）

### G23: `server-a/server-b` 主部署流与 `install.sh` 入口会在关键步骤失败后仍报完成/成功（已修复）

- **问题性质**:
  - root 与 bridge 的 `deploy_server_a()` 之前把 `setup_firewall`、`harden_ssh`、`setup_fail2ban`、`harden_kernel`、`deploy_mihomo`、`deploy_keepalive`、`deploy_split_tunnel`、`setup_logrotate`、`deploy_monitoring`、`test_connectivity` 中的大部分失败都降级成 warning；即使关键步骤失败，尾部仍照常打印 `Server A Deployment Complete!`，函数也返回成功。
  - 同一条 `server-a` 主流程里，用户一旦明确选择部署 `VPN`，旧实现仍把 `deploy_vpn` 失败降级成 `non-fatal` warning；root `install.sh` 里如果操作者继续选择部署 `bifrost-api`，`deploy_bifrost_api` 失败也只打一条 warning，主 flow 随后照样打印 `部署成功`。
  - root 与 bridge 的 `deploy_server_b()` 虽然已经有 `failed_steps`，但 `SSH/Firewall/Kernel/fail2ban/Auto Updates`、`Anti-DPI`、`Keepalive`、`Monitoring` 这些失败此前并没有纳入最终状态；`_print_deployment_summary()` 无论 `failed_steps` 是否为空都打印 `DEPLOYMENT COMPLETE`，而且调用与遍历 `failed_steps` 时都没有引用数组元素，像 `Firewall Setup` 这类步骤名还会被拆词，进一步破坏可观测性。
  - 更上层的 root / bridge `install.sh` 入口也在吞掉真实失败：菜单 flow 与 `--server-a` / `--server-b` CLI 入口之前都直接调用 `deploy_server_*`，随后无条件打印 `部署完成` / `部署成功` 并 `exit 0`。这意味着即使底层已经出现明确失败，顶层控制面仍继续给出成功态。
- **风险**:
  - 运维、教程执行者或外部自动化看到的是“部署成功”，但真实系统可能缺防火墙、缺 Mihomo、缺 keepalive、缺 monitoring，或连通性测试根本没有通过。这会把排障方向从“脚本未完成交付”误导到“域名/DNS/上游厂商/用户环境”。
  - `install.sh` 吞掉退出码还会让所有上层包装器、CI smoke、远程执行器都无法感知失败，直接把“脚本编排完成”和“系统真实可用”混为一谈。
  - `server-b` 的 failed step 拆词问题则会进一步损坏最后的摘要证据，使操作者连失败的真实步骤名都看不准。
- **修复文件**:
  - `scripts/server-a.sh`
  - `ai-gateway-bridge/scripts/server-a.sh`
  - `scripts/server-b.sh`
  - `ai-gateway-bridge/scripts/server-b.sh`
  - `install.sh`
  - `ai-gateway-bridge/install.sh`
  - `tests/test-in-docker.sh`
- **修复内容**:
  - `deploy_server_a()` 现在会显式聚合关键失败步骤：安全加固、Mihomo、VPN（当用户明确选择部署时）、keepalive、split tunnel、log rotation、monitoring、connectivity 只要任一失败，就记录到 `failed_steps`，尾部摘要切换为 `Server A Deployment Incomplete`，并以非 0 退出。
  - `deploy_server_b()` 现在把此前遗漏的安全加固、Anti-DPI、keepalive、monitoring 失败也纳入 `failed_steps`；`_print_deployment_summary()` 会根据真实状态切换 `COMPLETE/INCOMPLETE`，并把 failed step 的传参和遍历都改成正确的 quoted array，避免步骤名被拆词。
  - root 与 bridge `install.sh` 的菜单 flow 和 CLI 入口现在都会透传 `deploy_server_a` / `deploy_server_b` 的失败状态；一旦底层部署失败，就停止继续打印“部署成功”并返回非 0。root `install.sh` 里用户显式选择继续部署 `bifrost-api` 时，也会对 `deploy_bifrost_api` 失败做同样的非 0 透传，而不是 warning 后继续收口。
- **新增验证**:
  - `tests/test-in-docker.sh` 新增 `deploy` 套件，并纳入 `all`：
    - root `server-a` 在连通性失败时会返回失败，且不再打印完成摘要
    - bridge `server-a` 在连通性失败时会返回失败，且不再打印完成摘要
    - root `server-a` 在用户选择 VPN 且部署失败时会返回失败，且不再打印完成摘要
    - bridge `server-a` 在用户选择 VPN 且部署失败时会返回失败，且不再打印完成摘要
    - root `server-b` 在安全加固失败时会返回失败，且不再打印完成摘要
    - bridge `server-b` 在安全加固失败时会返回失败，且不再打印完成摘要
    - root / bridge `install.sh` 会透传 `deploy_server_a` / `deploy_server_b` 的失败状态
    - root `install.sh` 会透传 `deploy_bifrost_api` 的失败状态
- **本轮回归结果**:
  - `bash tests/test-in-docker.sh deploy` → `9 通过, 0 失败, 0 跳过`
  - `bash tests/test-in-docker.sh all` → `244 通过, 0 失败, 0 跳过`

### G24: `install.sh` / `ai-gateway-bridge/install.sh` 的通用 CLI 与菜单入口仍会把子命令失败吞成 `exit 0`（已修复）

- **问题性质**:
  - 在修完 G23 之后继续复查入口层时，又发现 root 与 bridge `install.sh` 里仍有一整组通用入口沿用旧模式：先调用底层命令，再无条件 `exit 0`，或者在菜单 flow 里直接调用后立刻打印完成。
  - 受影响的不只是 `--server-a` / `--server-b`。root `install.sh` 的 `--security`、`--health-check`、`--uninstall`、`--vpn`、`--anti-dpi`、`--mihomo`、`--keepalive`、`--split-tunnel`、`--backup`、`--update`、`--multi-server`、`--user-mgmt`、`--bifrost-api`、`--diagnostics`、`--dd-reinstall` 此前都属于“命令失败也 `exit 0`”。
  - bridge `install.sh` 同样保留了对应的大部分子命令；此外，两棵树的菜单 flow 里 `security_only_flow`、`monitoring_only_flow`、`whitelist_flow`、`health_check_flow`、`dd_reinstall_flow`、`vpn_flow`、`anti_dpi_flow`、`mihomo_flow`、`keepalive_flow`、`split_tunnel_flow` 等也没有统一按真实返回码收口。
- **风险**:
  - 这会让自动化调用者、文档执行者、CI smoke、远程面板乃至用户自己的 shell alias 都把真实失败误判成成功，范围比 G23 更广，因为它波及的是整套入口层，而不是单个部署编排函数。
  - 最典型的误导是 `--health-check` 或 `--dd-reinstall` 失败后仍 `exit 0`。这种情况下，调用方会以为环境健康或清理已完成，后续排障和下一步部署都会建立在错误前提上。
  - 菜单 flow 层若继续在失败后打印“完成”，会把“组件管理器内部失败”和“入口层成功完成”混成同一层语义，进一步稀释错误信号。
- **修复文件**:
  - `install.sh`
  - `ai-gateway-bridge/install.sh`
  - `tests/test-in-docker.sh`
- **修复内容**:
  - root 与 bridge `install.sh` 现在都新增统一的 `run_flow_command()` / `run_cli_command()` helper，用来集中处理 flow 与 CLI 子命令的失败传播。
  - 所有高价值 CLI 子命令现在都改为经由 `run_cli_command()` 收口，不再在底层命令失败后继续 `exit 0`。
  - 两棵树的菜单 flow 现在也会对关键一跳命令做真实判断：失败则 `log_error + return 1`，成功路径才允许打印后续成功提示。
  - root `whitelist_flow()` 也同步收口，避免白名单管理器失败时菜单入口仍静默返回成功。
- **新增验证**:
  - `tests/test-in-docker.sh` 扩展 `deploy` 套件，新增入口层合同：
    - root / bridge `install.sh` 必须存在统一的 `run_flow_command()` / `run_cli_command()` helper
    - root `install.sh` 的全部高价值 CLI 子命令必须走统一失败传播
    - bridge `install.sh` 的全部高价值 CLI 子命令必须走统一失败传播
    - root / bridge 菜单 flow 必须对 `whitelist`、`monitoring`、`dd-reinstall`、`vpn` 等关键命令失败做真实收口
- **本轮回归结果**:
  - `bash tests/test-in-docker.sh deploy` → `13 通过, 0 失败, 0 跳过`
  - `bash tests/test-in-docker.sh all` → `248 通过, 0 失败, 0 跳过`

### G25: `dd-reinstall` 的 `pre_deploy_check()` 会把前置清理失败与系统校验失败吞成成功（已修复）

- **问题性质**:
  - root 与 bridge 的 `scripts/dd-reinstall.sh` 中，`pre_deploy_check()` 之前把 `detect_cloud_provider`、`offer_dd_reinstall`、`verify_clean_system` 全部写成了 `|| true`，尾部还无条件 `return 0`。
  - `detect_cloud_provider` 的非零只代表“未知云厂商”，这本来是信息性结果，不应阻断；但 `offer_dd_reinstall` 的非零语义完全不同，它覆盖了“用户选择 Skip”“清理确认取消”“清理过程中失败”等真实未清理状态。
  - `verify_clean_system` 的非零同样是强信号，表示系统仍检测到残留 agent、异常内核/拥塞控制或可疑监听状态。旧实现却在发现 issue 后仍打印 `Pre-deployment check complete. Proceeding with deployment...`，把不干净环境继续送入正式部署。
- **风险**:
  - 这会让 `install.sh --dd-reinstall`、菜单里的预部署清理入口、以及任何把 `pre_deploy_check()` 当成部署前门禁的上层调用者，在“用户明确跳过清理”或“系统校验失败”时继续得到成功态。
  - 结果是后续的安全加固、Anti-DPI、Mihomo、VPN、保活与教程都会建立在错误前提上：控制面宣称环境已经 clean，真实机器却仍可能保留云厂商 agent 或其他探测面。
  - 因为这个缺口位于正式部署前的最后一道 hygiene gate，它不是单点功能 bug，而是整个部署可信度的基线漂移。
- **修复文件**:
  - `scripts/dd-reinstall.sh`
  - `ai-gateway-bridge/scripts/dd-reinstall.sh`
  - `tests/test-in-docker.sh`
- **修复内容**:
  - `pre_deploy_check()` 现在把“未知云厂商”与“真实阻断失败”分开处理：`detect_cloud_provider` 仍允许 unknown/bare metal 继续，但只作为信息展示，不再混入后续门禁语义。
  - `offer_dd_reinstall()` 的“云集成审查” / `Full DD Reinstall` 分支透传 `_do_light_clean()` / `_do_dd_reinstall()` 的真实返回码，不再把“确认取消”或底层失败重新包装成成功。
  - 当检测到云厂商集成项且 `offer_dd_reinstall()` 返回非零时，函数现在会记录 `Cloud integration review was not acknowledged. Deployment must stop.`，并以非 0 结束，而不是继续向下部署。
  - 当 `verify_clean_system()` 发现云就绪校验问题时，函数现在会记录 `Cloud readiness verification detected unresolved issues. Deployment must stop.`，并在尾部统一以 `Pre-deployment check failed. Resolve the issues above before deployment.` 做非 0 收口。
  - 成功路径才允许打印 `Pre-deployment check complete. Proceeding with deployment...`，从而把“信息性 unknown provider”与“真实未审查/未验证通过”的控制语义彻底拆开。
- **新增验证**:
  - `tests/test-in-docker.sh` 新增 `dd` 套件，并把 root / bridge 的 `pre_deploy_check` 合同纳入 `deploy` 与 `all`：
    - root `dd-reinstall` 在未知云厂商且系统干净时允许继续部署
    - bridge `dd-reinstall` 在未知云厂商且系统干净时允许继续部署
    - root `dd-reinstall` 在检测到 agent 但跳过清理时会阻断部署
    - bridge `dd-reinstall` 在检测到 agent 但跳过清理时会阻断部署
    - root `dd-reinstall` 在系统校验失败时会阻断部署
    - bridge `dd-reinstall` 在系统校验失败时会阻断部署
    - root `offer_dd_reinstall` 在 `Light Clean` / `Full DD Reinstall` 取消或失败时会透传非零
    - bridge `offer_dd_reinstall` 在 `Light Clean` / `Full DD Reinstall` 取消或失败时会透传非零
- **本轮回归结果**:
  - `bash tests/test-in-docker.sh dd` → `10 通过, 0 失败, 0 跳过`
  - `bash tests/test-in-docker.sh deploy` → `23 通过, 0 失败, 0 跳过`
  - `bash tests/test-in-docker.sh all` → `258 通过, 0 失败, 0 跳过`

### G26: `server-b` 主部署流仍把 `pre_deploy_check()` 失败降级成 non-fatal warning（已修复）

- **问题性质**:
  - 在 G25 修完之后继续追调用链，发现 root 与 bridge 的 `deploy_server_b()` 里仍保留了 `pre_deploy_check || log_warn "Pre-deploy check encountered issues (non-fatal)."`。
  - 这意味着即使 `dd-reinstall.sh` 已经明确返回“用户跳过清理”“系统校验失败”“环境不适合继续部署”，`server-b` 主流程仍会继续进入 `detect_system`、安全加固、Xray、3x-ui、Hysteria、Caddy、BBR、Anti-DPI、keepalive、monitoring 等后续步骤。
  - 问题不在 `pre_deploy_check()` 本身，而在其上层调用者仍把它当 advisory check 使用，导致 G25 在真正主部署路径里失效。
- **风险**:
  - 这会把“预部署清理门禁”重新降成展示性质的 warning，直接破坏零信任部署前提。对国内云厂商机器尤其危险，因为脚本会在 agent 仍存在、探测面仍未清理时继续下发完整流量栈。
  - 更糟的是，后续部署如果部分成功，操作者会得到大量“组件安装成功”的局部信号，误以为剩下问题只在路由或上游网络，而忽略真正的根因是门禁本应阻断却被上层绕过。
- **修复文件**:
  - `scripts/server-b.sh`
  - `ai-gateway-bridge/scripts/server-b.sh`
  - `tests/test-in-docker.sh`
- **修复内容**:
  - root / bridge `deploy_server_b()` 现在都会把 `pre_deploy_check()` 当成真实前置门禁：只要返回非零，就立即记录 `Pre-deploy check failed. Cannot continue with Server B deployment.` 并 `return 1`。
  - 修复后，`server-b` 在预部署清理失败时不会再进入 `[Step 1/14] Detecting system environment...` 及后续任何部署步骤，也不会打印 `DEPLOYMENT COMPLETE/INCOMPLETE` 摘要，避免把“前置门禁失败”和“主体部署失败”混成一条模糊状态。
- **新增验证**:
  - `tests/test-in-docker.sh` 的 `Server B 主部署状态一致性契约` 现在新增 root / bridge 两条用例：
    - root `server-b` 在预部署清理失败时会立即终止且不进入后续部署
    - bridge `server-b` 在预部署清理失败时会立即终止且不进入后续部署
- **本轮回归结果**:
  - `bash tests/test-in-docker.sh dd` → `10 通过, 0 失败, 0 跳过`
  - `bash tests/test-in-docker.sh deploy` → `25 通过, 0 失败, 0 跳过`
  - `bash tests/test-in-docker.sh all` → `260 通过, 0 失败, 0 跳过`

### G27: `backup rotate-ip` 会在预备份失败后继续改配置，破坏变更原子性（已修复）

- **问题性质**:
  - root 与 bridge 的 `scripts/backup.sh:emergency_ip_rotation()` 在进入破坏性配置修改前虽然会调用 `backup_config()`，但旧实现写成了 `backup_config || log_warn "Backup failed, but continuing with rotation."`。
  - 这不是普通 warning。`rotate-ip` 会直接修改 Xray client、Mihomo、连接说明和状态文件中的 Server B 地址，一旦备份失败却继续执行，就等于在没有 rollback evidence 的前提下做网络链路切换。
  - 该缺口与之前已修的“tunnel 验证失败不打印完成摘要”不同，它发生在更早的 mutate 前门禁，属于操作原子性断裂。
- **风险**:
  - 当备份目录不可写、加密失败、依赖缺失或归档过程异常时，操作者会失去最后一份变更前快照；如果后续 rotation 本身又失败，排障与回滚都会被放大成手工重建。
  - 对这类跨 Xray/Mihomo/连接文件的联动变更来说，“先备份、后修改”不是增强项，而是最基本的安全条件。旧实现把这个条件降成 warning，等于默认接受不可逆改动。
- **修复文件**:
  - `scripts/backup.sh`
  - `ai-gateway-bridge/scripts/backup.sh`
  - `tests/test-in-docker.sh`
- **修复内容**:
  - `emergency_ip_rotation()` 现在把 `backup_config()` 作为硬门禁：一旦预备份失败，就立即记录 `Pre-rotation backup failed. Refusing to continue with IP rotation.` 并 `return 1`。
  - 修复后，预备份失败时不会继续改动 Xray/Mihomo/连接状态文件，也不会打印 `IP rotation complete`。
  - `tests/test-in-docker.sh` 的这两条 root / bridge 用例也已改为显式状态收集，并在 `source common.sh` 后移除继承的 `EXIT/ERR` trap 干扰；从而避免 `powershell -> bash/WSL` 壳层下把业务已修好的场景误判成假失败。
- **新增验证**:
  - `tests/test-in-docker.sh` 的 `backup` 套件新增 root / bridge 两条用例：
    - root `backup rotate-ip` 在预备份失败时会拒绝修改配置
    - bridge `backup rotate-ip` 在预备份失败时会拒绝修改配置
- **本轮回归结果**:
  - `bash tests/test-in-docker.sh backup` → `14 通过, 0 失败, 0 跳过`
  - `bash tests/test-in-docker.sh all` → `262 通过, 0 失败, 0 跳过`

### G28: `server-a` 主部署流仍把 `pre_deploy_check()` 失败降级成 warning，导致门禁失效（已修复）

- **问题性质**:
  - 在 G25/G26 收口之后继续横向复查同类调用链，发现 root 与 bridge 的 `scripts/server-a.sh:deploy_server_a()` 仍保留了 `pre_deploy_check || log_warn "Pre-deploy check encountered issues (non-fatal)."`。
  - 这意味着即使 `dd-reinstall.sh` 已经明确返回“用户跳过清理”“系统校验失败”“环境不适合继续部署”，`server-a` 主流程仍会继续进入 `detect_system`、基础依赖安装、安全加固、Xray、New API、Caddy、VPN、Monitoring 与连通性测试等后续步骤。
  - 问题与先前 `server-b` 的 G26 同型，只是盲区还留在另一条主部署入口上。
- **风险**:
  - 这会把“预部署清理门禁”重新降成展示性质的 warning，直接破坏零信任入口的可信度。对国内云服务器尤其危险，因为脚本会在 agent 仍存在、探测面仍未清理时继续铺设完整公网入口和流量栈。
  - 更糟的是，操作者会在后续步骤里看到一串局部成功日志，从而把真正根因误判成上游网络、证书或路由问题，而忽略本应最先阻断的 hygiene gate。
- **修复文件**:
  - `scripts/server-a.sh`
  - `ai-gateway-bridge/scripts/server-a.sh`
  - `tests/test-in-docker.sh`
- **修复内容**:
  - root / bridge `deploy_server_a()` 现在都会把 `pre_deploy_check()` 当成真实前置门禁：只要返回非零，就立即记录 `Pre-deploy check failed. Cannot continue with Server A deployment.` 并 `return 1`。
  - 修复后，`server-a` 在预部署清理失败时不会再进入 `[Step 1/14] Detecting system environment...` 及后续任何部署步骤，也不会打印 `Server A Deployment Complete!` 成功摘要。
- **新增验证**:
  - `tests/test-in-docker.sh` 的 `Server A 主部署状态一致性契约` 现在新增 root / bridge 两条用例：
    - root `server-a` 在预部署清理失败时会立即终止且不进入后续部署
    - bridge `server-a` 在预部署清理失败时会立即终止且不进入后续部署
- **本轮回归结果**:
  - `bash tests/test-in-docker.sh deploy` → `27 通过, 0 失败, 0 跳过`
  - `bash tests/test-in-docker.sh all` → `264 通过, 0 失败, 0 跳过`

### G29: `monitoring` 把 `crontab` 存在误当成 cron 调度器可用，导致保活巡检出现控制面假成功（已修复）

- **问题性质**:
  - root 与 bridge 的 `scripts/monitoring.sh:ensure_crontab_available()` 旧实现只校验 `crontab` 命令是否存在，却不确认 `cron/crond` 调度器是否真实运行。
  - 更严重的是，旧链路里对调度器启动失败的处理带有 `|| true` 式吞错语义，导致 `setup_health_check()` / `deploy_monitoring()` 即使无法让调度器进入 active，也仍可能继续写入 crontab 并打印 `Health check cron job registered` / `Monitoring Deployment Complete`。
  - 这不是单纯的环境兼容性问题，而是控制面把“已注册定时任务”错误等同于“保活与健康巡检已经真的会执行”。
- **风险**:
  - 在国内云主机、精简系统镜像、容器宿主或被裁剪过的服务器环境里，`crontab` 二进制存在但 `cron/crond` 服务未运行并不罕见。旧实现会让操作者误以为保活脚本、健康检查、告警链路已经形成闭环，实际却根本没有调度器执行。
  - 这会把真正的根因从“巡检未启动”伪装成“上游网络偶发波动”“隧道不稳定”或“被动探测误杀”，直接削弱本项目对保活与反探测能力的可信度。
- **修复文件**:
  - `scripts/monitoring.sh`
  - `ai-gateway-bridge/scripts/monitoring.sh`
  - `tests/test-in-docker.sh`
- **修复内容**:
  - root / bridge `ensure_crontab_available()` 现在都先检查 `systemctl is-active` 与 `pgrep -x cron|crond`，明确区分“命令存在”和“调度器正在运行”。
  - 当 `crontab` 已存在但未检测到活动调度器时，脚本会显式尝试通过 `systemctl enable --now` 或 `service ... start` 拉起 `cron/crond`；如果启动失败或启动后仍未 active，会直接记录错误并 `return 1`，不再允许后续注册 cron entry。
  - 本轮复测还额外修正了桥接侧成功路径测试夹具：`test_bridge_monitoring_contracts()` 现在和 root 套件一致，先 stub 一个健康的 `pgrep` 返回值，避免测试结果被宿主机当前是否运行 cron 污染。
- **新增验证**:
  - `tests/test-in-docker.sh` 的 `monitoring` 套件现已覆盖 root / bridge 两条新合同：
    - root `monitoring` 在 `crontab` 存在但调度器未运行时会 fail-fast，且不会写入 `# bifrost-health-check`
    - bridge `monitoring` 在 `crontab` 存在但调度器未运行时会 fail-fast，且不会写入 `# ai-gateway-bridge-health-check`
- **本轮回归结果**:
  - `bash -n scripts/monitoring.sh ai-gateway-bridge/scripts/monitoring.sh tests/test-in-docker.sh` 通过
  - `bash tests/test-in-docker.sh monitoring` → `7 通过, 0 失败, 0 跳过`
  - `bash tests/test-in-docker.sh all` → `270 通过, 0 失败, 0 跳过`

### G30: `backup` 的 daily cron 仍会把 `crontab` 存在误当成调度器可用，导致备份计划出现控制面假成功（已修复）

- **问题性质**:
  - root 与 bridge 的 `scripts/backup.sh:_backup_ensure_crontab_available()` 旧实现只检查 `crontab` 命令本身，完全不验证 `cron/crond` 调度器是否真实运行。
  - 更糟的是，旧代码对 `systemctl enable --now cron|crond` 与 `service cron|crond start` 的失败统一挂了 `|| true`，即使启动命令失败或调度器根本没进入 active，也会继续回到 `setup_auto_backup()`，随后照常写入 crontab 并打印 `Daily backup cron job registered.`。
  - 这意味着“看上去已经注册了每日备份计划”与“实际上每天 03:00 会真的执行备份”被错误混为一谈。
- **风险**:
  - 对这套脚本体系来说，daily backup 不是附加功能，而是灾难恢复与变更回滚的最后兜底。若控制面误报 cron 已注册，操作者会在数天后才发现根本没有任何自动备份落地，届时回滚点已经永久缺失。
  - 在国内云主机、裁剪镜像、最小系统、容器宿主这类环境中，`crontab` 存在但 `cron/crond` 未运行是常见状态。旧实现会把这类环境静默误判成“备份策略已经生效”。
- **修复文件**:
  - `scripts/backup.sh`
  - `ai-gateway-bridge/scripts/backup.sh`
  - `tests/test-in-docker.sh`
- **修复内容**:
  - root / bridge `_backup_ensure_crontab_available()` 现在新增 `_backup_cron_scheduler_running()` 与 `_backup_start_cron_scheduler()`，明确检查 `systemctl is-active` 与 `pgrep -x cron|crond`，不再把 `crontab` 命令存在等同于调度器可用。
  - 当检测到 `crontab` 已存在但 scheduler 未运行时，脚本会显式尝试启动 `cron/crond`；若启动失败或启动后仍未 active，会直接 `return 1`，拒绝继续写入 daily backup cron entry。
  - 本轮同时修正了桥接侧 backup 成功路径的测试夹具，为正常注册场景补齐健康 `pgrep` stub，避免测试依赖宿主机当前是否有 cron 进程。
- **新增验证**:
  - `tests/test-in-docker.sh` 的 `backup` 套件现已新增 root / bridge 两条合同：
    - root `backup` 在 `crontab` 存在但调度器未运行时会 fail-fast，且不会写入 `# bifrost-daily-backup`
    - bridge `backup` 在 `crontab` 存在但调度器未运行时会 fail-fast，且不会写入 `# ai-gateway-bridge-daily-backup`
- **本轮回归结果**:
  - `bash -n scripts/backup.sh ai-gateway-bridge/scripts/backup.sh tests/test-in-docker.sh` 通过
  - `bash tests/test-in-docker.sh backup` → `16 通过, 0 失败, 0 跳过`
  - `bash tests/test-in-docker.sh all` → `263 通过, 0 失败, 1 跳过`
  - `bash tests/test-in-docker.sh docker` → `9 通过, 0 失败, 0 跳过`

### G31: `deploy_vpn()` 主编排会在关键步骤失败后继续打印 `VPN Deployment Complete`，破坏零信任第一道门禁的可信度（已修复）

- **问题性质**:
  - root 与 bridge 的 `scripts/vpn.sh:deploy_vpn()` 旧实现对 `detect_system`、`_vpn_check_prerequisites`、`setup_vpn_network`、`_vpn_install_wireguard`、`_vpn_generate_server_keys`、`_vpn_deploy_firezone/_vpn_deploy_headscale`、`setup_vpn_firewall` 都是裸调用，没有统一 `|| return 1`。
  - 这意味着只要某个关键步骤返回非零但没有在内部 `die` 直接终止，主流程就仍会继续落到尾部摘要，打印 `VPN Deployment Complete` 与 `Enterprise VPN is now the FIRST gate.`。
  - 该问题与先前 `server-a/server-b`、`monitoring`、`backup` 的控制面假成功属于同一类缺陷，只是位置落在“零信任第一道门禁”的主入口上，风险更高。
- **风险**:
  - VPN 是整套系统的第一层访问控制。若服务部署失败、防火墙配置失败、前置检测失败后仍然宣告“企业 VPN 已就绪”，操作者会误以为员工已经被强制收口到受控入口，实际却可能仍在公网裸奔。
  - 对国内服务器、探测敏感环境或多网段团队接入场景，这种假成功会直接把后续所有安全判断建立在错误前提上，属于体系级误导，而不是普通 UX 问题。
- **修复文件**:
  - `scripts/vpn.sh`
  - `ai-gateway-bridge/scripts/vpn.sh`
  - `tests/test-in-docker.sh`
- **修复内容**:
  - root / bridge `deploy_vpn()` 现在都会对前置环境探测、依赖校验、网络配置、VPN 服务部署、VPN 防火墙配置做显式失败透传；任何一步失败都会立刻记录错误并 `return 1`。
  - 修复后，`deploy_vpn()` 不会再在 `Headscale/Firezone` 部署失败或 `setup_vpn_firewall()` 失败后继续打印 `VPN Deployment Complete`，也不会再宣称“Enterprise VPN is now the FIRST gate.”。
- **新增验证**:
  - `tests/test-in-docker.sh` 的 `vpn` 套件现已新增 root / bridge 四条主编排合同：
    - root `deploy_vpn` 在 VPN 服务部署失败时会返回失败且不打印完成摘要
    - root `deploy_vpn` 在防火墙配置失败时会返回失败且不打印完成摘要
    - bridge `deploy_vpn` 在 VPN 服务部署失败时会返回失败且不打印完成摘要
    - bridge `deploy_vpn` 在防火墙配置失败时会返回失败且不打印完成摘要
- **本轮回归结果**:
  - `bash -n scripts/vpn.sh ai-gateway-bridge/scripts/vpn.sh tests/test-in-docker.sh` 通过
  - `bash tests/test-in-docker.sh vpn` → `8 通过, 0 失败, 0 跳过`
  - `bash tests/test-in-docker.sh all` → `276 通过, 0 失败, 0 跳过`

### G32: `keepalive` 的 heartbeat/watchdog systemd 部署不校验 unit 真正进入 active，导致保活链路仍可能出现控制面假成功（已修复）

- **问题性质**:
  - root 与 bridge 的 `scripts/keepalive.sh` 旧实现里，`setup_heartbeat_service()` / `setup_watchdog()` 对 `systemctl daemon-reload`、`systemctl enable`、`systemctl start` 基本都是裸调用。
  - 更严重的是，旧版 `setup_watchdog()` 即使在 `systemctl is-active --quiet ai-gateway-watchdog.service` 失败时，也只打印 `Watchdog service may not have started` warning，然后继续返回成功；`setup_heartbeat_service()` 甚至完全没有在启动后确认 timer 是否真的 active。
  - 由于 `deploy_keepalive()` 依赖这两个 helper 的返回值决定是否进入尾部摘要，结果就是 heartbeat timer / watchdog service 没有真正起来时，主流程仍可能打印 `Keepalive Deployment Complete`，把“保活服务单元文件写入成功”误报成“保活闭环已经真实生效”。
- **风险**:
  - `keepalive` 不是装饰性能力，而是面对运营商 NAT 超时、静默断链、服务异常退出时的关键保活与自愈层。若 heartbeat timer 没跑起来，探针不会执行；若 watchdog service 没进入 active，关键服务异常退出后也不会被拉起。
  - 在国内云主机、裁剪 systemd 环境、残缺镜像、混合容器宿主等场景里，`systemctl start` 返回异常、unit enable 失败、服务启动后立刻退出都很常见。旧实现会把这些真实故障伪装成“部署完成”，直接削弱本项目关于保活、抗静默掉线和规避探测恢复链路的可信度。
- **修复文件**:
  - `scripts/keepalive.sh`
  - `ai-gateway-bridge/scripts/keepalive.sh`
  - `tests/test-in-docker.sh`
- **修复内容**:
  - root / bridge `setup_heartbeat_service()` 现在都会对 `systemctl daemon-reload`、`enable ai-gateway-heartbeat.timer`、`start ai-gateway-heartbeat.timer` 做显式失败透传；启动后会再用 `systemctl is-active --quiet ai-gateway-heartbeat.timer` 做 active 校验，不满足即直接 `return 1`。
  - root / bridge `setup_watchdog()` 现在也会对 `daemon-reload`、`enable ai-gateway-watchdog.service`、`start ai-gateway-watchdog.service` 全部显式 fail-fast；若 watchdog 未进入 active，不再只是 warning，而是明确报错并返回非 0。
  - 为了让这类真实 helper 可以在合同测试里安全运行，本轮同时把 `SYSTEMD_UNIT_DIR` 与 `KEEPALIVE_STATE_DIR` 做成可覆盖变量，默认仍保持生产路径不变，但测试环境可以落到临时目录，不再依赖宿主机 `/etc/systemd/system` / `/var/lib/*`。
- **新增验证**:
  - `tests/test-in-docker.sh` 的 `keepalive` 套件现已新增 root / bridge 四条合同：
    - root `keepalive` 在 heartbeat timer 启动失败时会终止且不打印完成摘要
    - root `keepalive` 在 watchdog 未进入 active 时会终止且不打印完成摘要
    - bridge `keepalive` 在 heartbeat timer 启动失败时会终止且不打印完成摘要
    - bridge `keepalive` 在 watchdog 未进入 active 时会终止且不打印完成摘要
- **本轮回归结果**:
  - `bash -n scripts/keepalive.sh ai-gateway-bridge/scripts/keepalive.sh tests/test-in-docker.sh` 通过
  - `bash tests/test-in-docker.sh keepalive` → `8 通过, 0 失败, 0 跳过`
  - `bash tests/test-in-docker.sh all` → `280 通过, 0 失败, 0 跳过`

### G33: `run_security_audit()` 把 Lynis 执行失败吞成“审计已完成”，导致安全总评仍可能出现控制面假成功（已修复）

- **问题性质**:
  - root 与 bridge 的 `scripts/security.sh` 旧实现中，`run_security_audit()` 直接使用 `lynis audit system ... || true`，随后无条件 `cp` 报告、显示摘要，并打印 `Security audit complete. Full report: ...`。
  - 这意味着只要 `lynis` 二进制存在，但执行本身失败，`run_security_audit()` 仍会返回成功；`full_security_hardening()` 也会把第 8 步 `Security Audit` 记入 passed steps，而不是 failed steps。
  - 同样的问题还存在于 `_install_lynis()` 的首次审计里，旧代码把“Lynis 已安装”与“首次安全审计真实跑通”错误混为一谈。
- **风险**:
  - 这不是日志措辞问题，而是安全基线验证被直接伪造成功。操作者会看到“Full Security Hardening - Summary”里安全审计通过，实际上 Lynis 根本没有成功执行，最终 hardening score 和建议项也可能全部失真。
  - 在缺失权限、日志目录异常、Lynis 环境损坏、依赖损坏或受裁剪系统里，这类失败并不罕见。旧实现会把“审计器没跑起来”误导成“系统已经通过安全总检”，属于典型 zero-trust 破口。
- **修复文件**:
  - `scripts/security.sh`
  - `ai-gateway-bridge/scripts/security.sh`
  - `tests/test-in-docker.sh`
- **修复内容**:
  - root / bridge 现在新增 `_run_lynis_audit_report()`，统一要求 Lynis 审计必须返回 0 且产出非空报告；否则立即报错并返回非 0，不再允许 `run_security_audit()` 或 `_install_lynis()` 继续宣告成功。
  - `run_security_audit()` 现在会对 timestamped report 的生成和 latest report 的复制都做显式失败透传；一旦审计失败，就不会再打印 `Security audit complete`。
  - 为了让安全审计路径可以做真实合同测试，本轮同时把 `LYNIS_LOG_DIR`、`LYNIS_REPORT_FILE`、`LYNIS_DATA_FILE`、`LYNIS_CRON_FILE` 做成可覆盖变量；默认生产路径不变，但测试环境可以安全落到临时目录。
  - `tests/test-in-docker.sh` 也补齐了此前名存实亡的 `security` 分组，现在可以单独执行 `bash tests/test-in-docker.sh security` 跑 root / bridge 的安全审计 fail-fast 合同。
- **新增验证**:
  - `tests/test-in-docker.sh` 新增 root / bridge 两条合同：
    - root `security` 在 Lynis 审计失败时会返回失败并把 `Security Audit` 标记为失败
    - bridge `security` 在 Lynis 审计失败时会返回失败并把 `Security Audit` 标记为失败
- **本轮回归结果**:
  - `bash -n scripts/security.sh ai-gateway-bridge/scripts/security.sh tests/test-in-docker.sh` 通过
  - `bash tests/test-in-docker.sh security` → `12 通过, 0 失败, 0 跳过`
  - `bash tests/test-in-docker.sh all` → `283 通过, 0 失败, 1 跳过`
  - 唯一 `skip` 为 Docker 容器阶段 `apt-get install` 受环境网络限制

### G34: `harden_ssh()` 在新 SSH 端口防火墙放行失败时仍可能继续切换配置，存在锁死当前运维会话的风险（已修复）

- **问题性质**:
  - root 与 bridge 的 `scripts/security.sh` 旧实现中，`harden_ssh()` 会先把 `Port`、`PasswordAuthentication` 等关键 SSH 配置写入 `sshd_config`，随后才尝试放行新端口。
  - 在旧代码里，防火墙切换这一步缺少统一的失败透传与回滚兜底；一旦 `ufw allow` / `firewall-cmd --add-port` / `firewall-cmd --reload` 失败，流程仍可能继续进入 `systemctl restart sshd`，最终让操作者看到 `SSH hardening complete.`，但新端口其实并未真正开放。
- **风险**:
  - 这不是普通 warning，而是直接影响运维会话存活。若 SSH 端口已写入新值、旧会话关闭，而新端口没有真正被防火墙放行，操作者会被服务器直接锁在门外。
  - 在国内云主机、最小化镜像、裁剪 firewalld/ufw 环境、云安全组与本机防火墙叠加的场景里，新端口放行失败并不罕见。旧实现会把“切口未打开”误报成“SSH 加固已完成”，属于典型 zero-trust 破口。
- **修复文件**:
  - `scripts/security.sh`
  - `ai-gateway-bridge/scripts/security.sh`
  - `tests/test-in-docker.sh`
- **修复内容**:
  - root / bridge 现在新增 `_open_ssh_port_in_firewall()`，统一对 `ufw` / `firewalld` 的新旧端口放行与 `firewalld --reload` 做显式失败透传；任一步骤失败都立即返回非 0。
  - `harden_ssh()` 现在在防火墙切换失败时会恢复 `sshd_config` 备份并直接中止，不再继续进入 `systemctl restart sshd` / `systemctl restart ssh`。
  - 同时把 `SSHD_CONFIG_PATH`、`SSH_ADMIN_DIR`、`SSH_AUTHORIZED_KEYS_FILE`、`SSHD_BACKUP_DIR` 做成可覆盖变量，便于在合同测试里安全验证真实回滚路径。
- **新增验证**:
  - `tests/test-in-docker.sh` 新增 root / bridge 两条合同：
    - root `harden_ssh` 在防火墙放行新端口失败时会终止且不会重启 `sshd`
    - bridge `harden_ssh` 在防火墙放行新端口失败时会终止且不会重启 `sshd`
- **本轮回归结果**:
  - `bash -n scripts/security.sh ai-gateway-bridge/scripts/security.sh tests/test-in-docker.sh` 通过
  - `bash tests/test-in-docker.sh security` → `12 通过, 0 失败, 0 跳过`
  - `bash tests/test-in-docker.sh all` → `283 通过, 0 失败, 1 跳过`
  - 唯一 `skip` 为 Docker 容器阶段 `apt-get install` 受环境网络限制

### G35: `audit_ports()` 把端口阻断失败与最小环境解析失败伪装成“已封禁/无异常”，导致端口审计仍可能出现控制面假成功（已修复）

- **问题性质**:
  - root 与 bridge 的 `scripts/security.sh:audit_ports()` 旧实现中，当用户选择封禁非白名单端口后，`ufw deny`、`firewall-cmd --add-rich-rule` 与 `firewall-cmd --reload` 都被 `|| true` 吞掉；即使真正阻断失败，尾部仍无条件打印 `Non-whitelisted ports have been blocked.`。
  - 旧版端口解析还依赖 `awk '{print $4}' | rev | cut -d':' -f1 | rev`。在精简环境里若 `rev` 缺失，函数会把未知监听端口直接跳过，最终错误输出 `All listening ports are whitelisted. No issues found.`。
- **风险**:
  - 操作者以为自己已经封掉了未知监听端口，实际上端口仍然开放，或审计器干脆没有识别到异常监听。这会直接削弱本项目对“异常端口发现与阻断”的可信度。
  - 在裁剪容器、最小化 Debian/Ubuntu 镜像、国内云主机自定义镜像中，`rev` 不存在并不罕见。旧实现会把“审计器解析失败”误导成“系统端口正常”，属于隐蔽但高价值的控制面撒谎。
- **修复文件**:
  - `scripts/security.sh`
  - `ai-gateway-bridge/scripts/security.sh`
  - `tests/test-in-docker.sh`
- **修复内容**:
  - root / bridge 现在新增 `_block_port_in_firewall()`，统一要求 `ufw deny`、`firewalld rich-rule` 必须成功；`audit_ports()` 会聚合 `block_failures`，任一端口阻断或 `firewalld --reload` 失败都会返回非 0，并禁止打印“端口已封禁”成功摘要。
  - 端口解析已改为纯 shell 参数展开，不再依赖 `rev` 这类外部工具；最小环境下也能正确识别 `0.0.0.0:PORT`、`[::]:PORT` 这类监听地址。
- **新增验证**:
  - `tests/test-in-docker.sh` 新增 root / bridge 四条合同：
    - root `audit_ports` 在 `ufw deny` 失败时会返回失败且不宣称端口已封禁
    - root `audit_ports` 在 `firewalld reload` 失败时会返回失败且不宣称端口已封禁
    - bridge `audit_ports` 在 `ufw deny` 失败时会返回失败且不宣称端口已封禁
    - bridge `audit_ports` 在 `firewalld reload` 失败时会返回失败且不宣称端口已封禁
  - 上述合同运行环境本身未提供 `rev`，因此同时验证了新解析逻辑不再依赖该外部命令。
- **本轮回归结果**:
  - `bash -n scripts/security.sh ai-gateway-bridge/scripts/security.sh tests/test-in-docker.sh` 通过
  - `bash tests/test-in-docker.sh security` → `12 通过, 0 失败, 0 跳过`
  - `bash tests/test-in-docker.sh all` → `283 通过, 0 失败, 1 跳过`
  - 唯一 `skip` 为 Docker 容器阶段 `apt-get install` 受环境网络限制

### G36: `setup_firewall()` 的 ufw/firewalld helper 不校验关键命令返回值，导致防火墙未真正生效时仍可能输出 `Firewall setup complete.`（已修复）

- **问题性质**:
  - root 与 bridge 的 `setup_firewall()` 旧实现中，`_setup_firewall_ufw()` 与 `_setup_firewall_firewalld()` 绝大多数关键命令都是裸调用，包括 `ufw --force reset`、`ufw default deny incoming`、`ufw --force enable`、`systemctl enable --now firewalld`、`firewall-cmd --set-default-zone`、`--add-port`、`--add-service`、`--set-target=DROP`、`--reload` 等。
  - 因为这些命令没有统一 `|| return 1` 包裹，而 helper 尾部又总会继续执行 `_save_state` 并返回成功，`setup_firewall()` 即使在关键规则没有真正写入时，仍会打印 `Firewall setup complete.`。
- **风险**:
  - 这意味着操作者看到的是“默认拒绝、仅开放必要端口”的假象，实际系统可能根本没有进入预期的 zero-trust 防火墙状态。
  - 这种问题的危害不止是日志错，而是安全边界失真。无论是 `ufw reset` 失败、`firewalld` 默认 zone 没有切换成功，还是 `DROP` target 没有真正生效，都会让后续关于 SSH/VPN/Mihomo/监控暴露面的判断建立在错误前提上。
- **修复文件**:
  - `scripts/security.sh`
  - `ai-gateway-bridge/scripts/security.sh`
  - `tests/test-in-docker.sh`
- **修复内容**:
  - root / bridge 现在新增 `_run_firewall_step()`，统一要求每一个关键防火墙命令都必须成功；任一步骤失败都会立即打出业务级错误并返回非 0。
  - `setup_firewall()` 在 `ufw`、`firewalld`、以及“未检测到防火墙后自动安装”的三条路径上都改为显式失败透传；不再允许 helper 失败后继续打印 `Firewall setup complete.`。
  - `firewalld` 的默认 `ssh` service 移除改为先 `query-service` 再决定是否移除，避免把“本来就没启用 ssh service”的状态误判成失败。
- **新增验证**:
  - `tests/test-in-docker.sh` 新增 root / bridge 四条合同：
    - root `setup_firewall` 在 `ufw reset` 失败时会返回失败且不宣称已完成
    - root `setup_firewall` 在 `firewalld` 关键步骤失败时会返回失败且不宣称已完成
    - bridge `setup_firewall` 在 `ufw reset` 失败时会返回失败且不宣称已完成
    - bridge `setup_firewall` 在 `firewalld` 关键步骤失败时会返回失败且不宣称已完成
- **本轮回归结果**:
  - `bash -n scripts/security.sh ai-gateway-bridge/scripts/security.sh tests/test-in-docker.sh` 通过
  - `bash tests/test-in-docker.sh security` → `12 通过, 0 失败, 0 跳过`
  - `bash tests/test-in-docker.sh all` → `283 通过, 0 失败, 1 跳过`
  - 唯一 `skip` 为 Docker 容器阶段 `apt-get install` 受环境网络限制

### G37: `setup_fail2ban()` 在过滤器/`jail.local`/服务重启失败时仍可能宣称 `fail2ban setup complete.`，导致入侵封禁面出现控制面假成功（已修复）

- **问题性质**:
  - root 与 bridge 的 `scripts/security.sh:setup_fail2ban()` 旧实现中，`apt-get/dnf/yum` 安装、`mkdir -p`、filter heredoc、`jail.local` heredoc、`systemctl enable fail2ban`、`systemctl restart fail2ban` 都没有统一失败透传。
  - 旧代码即使在 filter 写入失败、`jail.local` 落盘失败、`systemctl restart fail2ban` 失败，甚至服务根本没有进入 active 状态时，尾部仍会继续打印 `fail2ban setup complete.` 并返回成功。
- **风险**:
  - SSH 与 Web 探测封禁链路会被直接伪装成“已启用”，而真实系统可能没有任何有效 jail 在运行。对国内云主机、裁剪镜像、最小化系统尤其危险，因为 `fail2ban` 常常正是防暴力破解和爬虫探测的第一道动态门禁。
  - 这不是日志细节问题，而是零信任策略面被错误上色为绿色。操作者会误以为 SSH 暴力破解与扫描探测已进入自动封禁状态，实际上入侵面仍裸露。
- **修复文件**:
  - `scripts/security.sh`
  - `ai-gateway-bridge/scripts/security.sh`
  - `tests/test-in-docker.sh`
- **修复内容**:
  - root / bridge 现在新增 `FAIL2BAN_FILTER_DIR`、`FAIL2BAN_JAIL_FILE`、`FAIL2BAN_SERVICE_NAME` 可覆盖变量，便于在合同测试里把真实路径落到临时目录。
  - `setup_fail2ban()` 现在对安装、目录创建、filter/jail 写入、`systemctl enable/restart` 全部做显式失败透传；任一步骤失败都会立即返回非 0。
  - 服务重启后新增 `systemctl is-active --quiet` 校验；只有服务真正 active 才允许打印 `fail2ban setup complete.`。
- **新增验证**:
  - `tests/test-in-docker.sh` 新增 root / bridge 两条合同：
    - root `setup_fail2ban` 在服务重启失败时会返回失败且不宣称已完成
    - bridge `setup_fail2ban` 在服务重启失败时会返回失败且不宣称已完成
- **本轮回归结果**:
  - `bash -n scripts/security.sh ai-gateway-bridge/scripts/security.sh tests/test-in-docker.sh` 通过
  - `bash tests/test-in-docker.sh security` → `22 通过, 0 失败, 0 跳过`
  - `bash tests/test-in-docker.sh all` → `302 通过, 0 失败, 0 跳过`

### G38: `setup_auto_updates()` / `_setup_auto_updates_debian()` 会把验证失败洗成“自动安全更新已配置”，导致更新门禁仍可能出现控制面假成功（已修复）

- **问题性质**:
  - root 与 bridge 的 `setup_auto_updates()` 旧实现只是裸调 `_setup_auto_updates_debian()` / `_setup_auto_updates_rhel_dnf()`，尾部无条件打印 `Automatic security updates configured.`。
  - Debian 路径此前使用 `unattended-upgrades --dry-run --debug 2>&1 | head -5` 做“验证”。因为没有 `pipefail`，前面的 `unattended-upgrades` 即使返回非 0，也会被 `head` 的成功退出码洗成成功。
  - 同一条链路中，`apt-get update/install`、配置文件写入、`dnf-automatic.timer` 启动等关键步骤也缺少统一失败透传。
- **风险**:
  - 操作者会看到“自动安全更新已启用”，但真实系统可能既没有成功安装 `unattended-upgrades` / `dnf-automatic`，也没有完成 dry-run 验证或 timer 启动。这会直接破坏对补丁时效性和暴露面修补能力的判断。
  - 在国内网络、裁剪镜像或只读系统里，这类失败并不少见。旧实现把“更新器没真正工作”误导成“补丁门禁已到位”，属于典型 zero-trust 假成功。
- **修复文件**:
  - `scripts/security.sh`
  - `ai-gateway-bridge/scripts/security.sh`
  - `tests/test-in-docker.sh`
- **修复内容**:
  - root / bridge 现在新增 `AUTO_UPGRADES_CONFIG_FILE`、`AUTO_UPGRADES_PERIODIC_FILE`、`DNF_AUTOMATIC_CONFIG_FILE`、`DNF_AUTOMATIC_TIMER_NAME` 可覆盖变量，用于安全合同测试。
  - `setup_auto_updates()` 现在会显式传播 helper 失败，不再在底层失败后继续打印 `Automatic security updates configured.`。
  - `_setup_auto_updates_debian()` 改为对 `apt-get update/install`、配置目录创建、配置写入逐步 fail-fast；并使用 `mktemp` 保存 dry-run 日志，按 `unattended-upgrades` 的真实退出码判定成功与失败，不再依赖 `| head`。
  - `_setup_auto_updates_rhel_dnf()` 现在对 `dnf install`、配置写入、`systemctl enable --now`、`systemctl is-active` 做显式校验，只有 timer 真正 active 才返回成功。
- **新增验证**:
  - `tests/test-in-docker.sh` 新增 root / bridge 两条合同：
    - root `setup_auto_updates` 在 `unattended-upgrades` 验证失败时会返回失败且不宣称已完成
    - bridge `setup_auto_updates` 在 `unattended-upgrades` 验证失败时会返回失败且不宣称已完成
- **本轮回归结果**:
  - `bash -n scripts/security.sh ai-gateway-bridge/scripts/security.sh tests/test-in-docker.sh` 通过
  - `bash tests/test-in-docker.sh security` → `22 通过, 0 失败, 0 跳过`
  - `bash tests/test-in-docker.sh all` → `302 通过, 0 失败, 0 跳过`

### G39: `install_security_tools()` / `_install_rkhunter()` / `_install_lynis()` 会把安全工具安装与巡检失败伪装成“安装完成”，导致主加固摘要仍可能出现控制面假成功（已修复）

- **问题性质**:
  - root 与 bridge 的 `install_security_tools()` 旧实现中，`_install_rkhunter` 与 `_install_lynis` 都是裸调用，尾部无条件打印 `Security tools installation complete.`。只要子安装器任一失败，wrapper 仍会返回成功。
  - `_install_rkhunter()` 旧实现还存在更深层吞错：`apt-get/dnf/yum` 安装缺少统一失败透传，`rkhunter --check --skip-keypress --report-warnings-only 2>&1 | tail -20 || true` 会把初始扫描失败直接洗掉，weekly cron 写入和 `chmod` 失败后仍继续打印 `rkhunter installation and configuration complete.`。
  - `_install_lynis()` 在 cron 物化层同样缺少显式校验：monthly cron 的目录创建、文件写入与 `chmod` 一旦失败，旧实现仍会继续把 Lynis 安装链路染成成功。
- **风险**:
  - 这意味着 `full_security_hardening()` 第 6 步 `Security Tools` 之前可能把“rkhunter/Lynis 没装好、首轮扫描失败、周期任务没有落地”错误包装成“安全工具已安装”。操作者看到的是绿色摘要，真实系统却缺少最基础的持续巡检与周期审计能力。
  - 与 G33 不同，这一缺口发生在安全审计器安装阶段本身；即使最终 Lynis 审计路径被修好，若安装器层继续撒谎，依然会把“审计器/扫描器未部署完毕”误导成“安全工具已到位”。
- **修复文件**:
  - `scripts/security.sh`
  - `ai-gateway-bridge/scripts/security.sh`
  - `tests/test-in-docker.sh`
- **修复内容**:
  - `install_security_tools()` 现在显式透传 `_install_rkhunter()` / `_install_lynis()` 的失败，只要任一子安装器失败，就立即返回非 0 并停止打印完成摘要。
  - root / bridge 新增 `RKHUNTER_CONF_FILE`、`RKHUNTER_CRON_FILE` 可覆盖变量；`_install_rkhunter()` 现在对安装、关键配置写入、初始扫描、weekly cron 目录创建/写入/`chmod` 做显式失败透传。
  - `_install_rkhunter()` 的初始扫描已改为基于临时日志文件按真实退出码判定，不再用 `| tail` 洗掉失败。
  - `_install_lynis()` 现在也对仓库 bootstrap 关键步骤、Git fallback 更新、monthly cron 目录创建/写入/`chmod` 做显式失败透传，拒绝在周期审计未落地时宣称安装完成。
- **新增验证**:
  - `tests/test-in-docker.sh` 新增 root / bridge 六条合同：
    - root `install_security_tools` 在子安装器失败时会返回失败且不宣称已完成
    - bridge `install_security_tools` 在子安装器失败时会返回失败且不宣称已完成
    - root `_install_rkhunter` 在初始扫描失败时会返回失败且不宣称已完成
    - bridge `_install_rkhunter` 在初始扫描失败时会返回失败且不宣称已完成
    - root `_install_lynis` 在月度 cron 物化失败时会返回失败且不宣称已完成
    - bridge `_install_lynis` 在月度 cron 物化失败时会返回失败且不宣称已完成
- **本轮回归结果**:
  - `bash -n scripts/security.sh ai-gateway-bridge/scripts/security.sh tests/test-in-docker.sh` 通过
  - `bash tests/test-in-docker.sh security` → `28 通过, 0 失败, 0 跳过`
  - `bash tests/test-in-docker.sh all` → `308 通过, 0 失败, 0 跳过`

### G40: `harden_ssh()` 在 SSH daemon restart 失败但旧服务仍 active 时仍可能误报成功，且 state/sshd_config override 之前并未真正生效（已修复）

- **问题性质**:
  - root 与 bridge 的旧实现虽然暴露了 `SECURITY_STATE_DIR`、`SECURITY_STATE_FILE`、`SSHD_CONFIG_PATH` 这些变量，但 `_get_ssh_port()` 仍硬读 `/etc/ssh/sshd_config`，`_set_sshd_option()` 默认仍写 `/etc/ssh/sshd_config`，`_save_state()` 也会继续落向默认 state 路径，导致测试或隔离环境里的 override 形同虚设。
  - `harden_ssh()` 的 restart 路径旧逻辑只在配置写完后检查 `systemctl is-active`。如果 `systemctl restart sshd` 失败，但旧的 `sshd` 进程依然处于 active，流程仍会打印 `sshd restarted successfully on port ...` 与 `SSH hardening complete.`。
- **风险**:
  - 这会把“SSH daemon 并未成功应用新配置”包装成“加固已完成”，操作者可能在未真正重载新配置的情况下误以为新端口、禁用密码登录、禁止 root 口令等策略已经生效。
  - 由于 override 之前并未真正接管底层读写路径，合同测试或临时隔离环境里的验证会偷偷打到真实 `/etc/...`；这不仅污染验证现场，也让 rollback / state persistence 的测试结论失真。
- **修复文件**:
  - `scripts/security.sh`
  - `ai-gateway-bridge/scripts/security.sh`
  - `tests/test-in-docker.sh`
- **修复内容**:
  - `SECURITY_STATE_DIR`、`SECURITY_STATE_FILE`、`SSHD_CONFIG_PATH`、`SSHD_BACKUP_DIR` 现在都真正作为可覆盖变量参与运行时路径解析，不再只是表面常量。
  - `_get_ssh_port()` 与 `_set_sshd_option()` 已统一改为跟随 `SSHD_CONFIG_PATH` 读取/写入，避免 override 后仍偷偷打回 `/etc/ssh/sshd_config`。
  - 新增 `_restart_ssh_service()` helper：只有“重启命令成功”且“同一服务重启后仍 active”同时成立时，才允许继续打印成功摘要；否则立即恢复备份并返回失败。
- **新增验证**:
  - `tests/test-in-docker.sh` 新增 root / bridge 两条合同：
    - root `harden_ssh` 在重启失败但服务仍 active 时会返回失败并恢复备份
    - bridge `harden_ssh` 在重启失败但服务仍 active 时会返回失败并恢复备份
- **本轮回归结果**:
  - `bash -n scripts/security.sh ai-gateway-bridge/scripts/security.sh tests/test-in-docker.sh` 通过
  - `bash tests/test-in-docker.sh security` → `28 通过, 0 失败, 0 跳过`
  - `bash tests/test-in-docker.sh all` → `308 通过, 0 失败, 0 跳过`

### G41: `_install_rkhunter()` 生成的 weekly cron 仍会把周期扫描失败吞成成功，导致持续巡检链路继续失真（已修复）

- **问题性质**:
  - 虽然 G39 已修掉 `_install_rkhunter()` 安装阶段的假成功，但旧版 weekly cron payload 仍写死 `/usr/bin/rkhunter` 与 `/var/log`，并继续使用 `--update ... || true`、`--check ... || true`。
  - 这意味着安装器层已经诚实返回失败，但一旦周期任务真正落地，后续每周的 rkhunter 更新/扫描仍可能在运行时持续失败却保持 0 退出，形成“安装阶段诚实、运行阶段继续撒谎”的裂缝。
- **风险**:
  - 操作者会看到 security hardening 已完成，也会看到 weekly cron 已生成，但真正的定期扫描可能早已失效，日志与退出码却不再向控制面暴露异常。
  - 这属于比 G39 更隐蔽的一类问题：它不再发生在首次部署，而是发生在长期运行期间，会让“持续巡检”在数周内静默失真。
- **修复文件**:
  - `scripts/security.sh`
  - `ai-gateway-bridge/scripts/security.sh`
  - `tests/test-in-docker.sh`
- **修复内容**:
  - weekly rkhunter cron 现在生成 `RKHUNTER_BIN`、`RKHUNTER_LOG_DIR` 两个具备默认值的可覆盖变量，避免继续把运行路径硬编码进脚本正文。
  - `rkhunter --check` 失败时会显式写入 `[rkhunter-cron] scan failed.` 并返回非 0；`rkhunter --update` 失败也不再被静默吞掉，而是记录失败并在本轮任务结束时返回非 0。
  - log rotation 也已切换到 `RKHUNTER_LOG_DIR`，避免 runtime script 一边宣称支持 override、一边仍偷偷清理固定 `/var/log`。
- **新增验证**:
  - `tests/test-in-docker.sh` 新增 root / bridge 两条静态合同：
    - root `_install_rkhunter` 生成的 weekly cron 不再吞掉扫描失败
    - bridge `_install_rkhunter` 生成的 weekly cron 不再吞掉扫描失败
  - 合同会检查新生成的 cron payload 已包含可覆盖的 `RKHUNTER_BIN` / `RKHUNTER_LOG_DIR`，包含显式失败标记，并且不再残留 `|| true` 的旧吞错写法。
- **本轮回归结果**:
  - `bash -n scripts/security.sh ai-gateway-bridge/scripts/security.sh tests/test-in-docker.sh` 通过
  - `bash tests/test-in-docker.sh security` → `28 通过, 0 失败, 0 跳过`
  - `bash tests/test-in-docker.sh all` → `308 通过, 0 失败, 0 跳过`

### G42: SSH 5 分钟 safety revert 脚本会吞掉后台恢复失败，导致“自动回滚兜底”本身仍可能是假成功（已修复）

- **问题性质**:
  - `harden_ssh()` 在端口变更场景下会生成 `/tmp/ssh-revert-safety.sh` 作为 5 分钟自动回滚兜底，但旧脚本内部对 `cp -p "${BACKUP_FILE}" "${SSHD_CONFIG}"` 没有显式失败判断。
  - 更关键的是，旧脚本仍使用 `systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null || true`，随后无条件输出 `Old port ... should be active again.`。由于主流程用 `nohup bash "${revert_script}" &>/dev/null &` 后台执行，操作者完全看不到这类恢复失败。
- **风险**:
  - 这意味着即使 G40 已修掉主链路上的 restart 假成功，只要用户真的触发 5 分钟 safety revert，后台恢复脚本仍可能在“配置复制失败”或“SSH daemon 根本没重启成功”的情况下静默退出，把最后一道防锁死兜底也变成假象。
  - 这是比主链路更隐蔽的恢复风险，因为它发生在操作者已经失去新端口连接、正在依赖自动回滚救场的时刻。
- **修复文件**:
  - `scripts/security.sh`
  - `ai-gateway-bridge/scripts/security.sh`
  - `tests/test-in-docker.sh`
- **修复内容**:
  - 生成的 safety revert 脚本现在会先显式校验备份回拷是否成功，失败时立即输出错误并以非 0 退出。
  - `systemctl restart sshd` / `systemctl restart ssh` 现在必须至少有一个真实成功；若两者都失败，会输出 `Failed to restart SSH daemon after revert. Manual recovery required.` 并退出，而不再用 `|| true` 硬吞掉。
  - 脚本只会在真正完成回拷与 daemon restart 后才继续打印“旧端口应已恢复”的成功提示并自删除。
- **新增验证**:
  - `tests/test-in-docker.sh` 新增 root / bridge 两条静态合同：
    - root `harden_ssh` 生成的 safety revert 脚本不再吞掉 SSH 恢复失败
    - bridge `harden_ssh` 生成的 safety revert 脚本不再吞掉 SSH 恢复失败
  - 合同会直接检查生成出的 `/tmp/ssh-revert-safety.sh` 已包含显式失败文案，并且不再残留 `systemctl ... || true` 的旧写法。
- **本轮回归结果**:
  - `bash -n scripts/security.sh ai-gateway-bridge/scripts/security.sh tests/test-in-docker.sh` 通过
  - `bash tests/test-in-docker.sh security` → `28 通过, 0 失败, 0 跳过`
  - `bash tests/test-in-docker.sh all` → `308 通过, 0 失败, 0 跳过`

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

---

## 当前阶段结论

**事实**: 当前报告已经同时对“部署脚本 + 配置模板 + 端到端流量路径 + `bifrost-api` 管理面契约”建立了可重复验证的证据链，并把最新补审继续推进到 `server-a/server-b` 主部署编排、`install.sh` / `ai-gateway-bridge/install.sh` 的通用 CLI 与菜单入口状态传播、`keepalive`、`multi-server`、`user-management`、`whitelist`、`backup rotate-ip`、`diagnostics` 报告导出，以及 `bifrost-api` 管理脚本本身的控制面原子性问题。

**推论**: 先前把仓库内静态补审判定为“收益明显下降”是过早收敛。后续几轮补审持续挖出了同一家族的高信号问题：前置依赖失败后仍打印完成摘要、本地 registry/whitelist 先成功而真实路由或交付未完成、子域名标准化与真实 route-engine 删除不一致，以及“容器命令已触发”“配置文件已写入”甚至“报告文件已导出”被误写成“管理平台/流量入口/诊断 artifact 已真实可用”。

**结论**: 代码级补审仍然有收益，且这一轮再次证明“本地状态先成功、真实交付后补”的模式是这套脚本的高频风险源。当前 `server-a/server-b` 主部署流、`install.sh` / `ai-gateway-bridge/install.sh` 的通用 CLI 与菜单入口状态传播、`create_user()` / `disable_user()` / `whitelist` / `backup.sh rotate-ip` / `diagnostics.sh` 报告导出 / `bifrost-api` 管理脚本的高价值假成功已经收口；下一优先级应继续转向同家族剩余链路，重点复查其它 `Skipping ... continue`、`warn and continue`、`summary before verify` 路径中是否仍存在“证据不足但摘要宣告完成”的控制面漂移。
