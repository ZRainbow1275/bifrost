# 员工接入流程 vs v2 bundle 审查

> 审查范围：`scripts/user-management.sh`（1376 行）、`scripts/vpn.sh`、`configs/vpn/wg-client.conf.tpl`、`docs/CLIENT-SETUP.md`、`docs/VPN-SETUP.md`、`docs/USAGE.md`。
> 对照：`prompts/server-a-hardening-strategy.md` v2 §3.3、§13.5、§14。
> 结论先行：**v2 要求的"客户端 bundle"在当前代码库零实现**。`create_user` 只产出 Markdown 指南 + WG 单文件，没有 CA、没有镜像配置片段、没有打包。员工接入复杂度突增是被严重低估的工程问题。

---

## 1. 当前 add_user 流程

### 实际生成的文件（`user-management.sh:581-743 create_user()`）

| 产物 | 路径 | 来源行 | 内容 |
|---|---|---|---|
| 用户注册表行 | `/etc/bifrost/users/registry.conf` | `user-management.sh:699` | `USERNAME\|UUID\|EMAIL\|active\|TOKEN_ID\|CREATED\|` |
| 凭据文件 | `/etc/bifrost/users/<u>.credentials` | `:703-718` | `USERNAME / EMAIL / VPN_UUID / API_TOKEN_KEY / API_TOKEN_ID / WG_CONFIG` |
| 入职指南 | `/etc/bifrost/users/guides/<u>-guide.md` | `:1046-1247` | Markdown，含 Xray UUID/SNI/Reality + Claude/Codex 环境变量 |
| WireGuard 配置 | `/etc/bifrost/vpn/users/<u>/wg-<u>.conf` | `vpn.sh:913-941`（间接调用 `create_vpn_user`） | 见下表 |
| QR 码 | `${user_dir}/qrcode.{txt,png}` | `vpn.sh:946-950` | 仅 WG conf |
| `SETUP-GUIDE.txt` | `${user_dir}/SETUP-GUIDE.txt` | `vpn.sh:1055-1151` | 纯文本步骤 |

### WG 客户端模板当前值（`configs/vpn/wg-client.conf.tpl` + `vpn.sh:917-925`）

| 字段 | 当前值 | v2 要求 | Δ |
|---|---|---|---|
| `Endpoint` | `${PUBLIC_IP}:51820` (`vpn.sh:51,910`) | `<A>:<30000-65000 随机>` (`strategy §4.1`) | 端口硬编码 51820，**v2 要求随机化** |
| `DNS` | `10.8.0.1` (`vpn.sh:920,932`) | `10.8.0.1` | ✅ 已对齐 |
| `AllowedIPs` | `10.8.0.0/24,172.16.0.0/24` (`vpn.sh:924,938`) | `10.8.0.0/24 + B_IP/32` (split-tunnel) | **方向不同**：当前路由 service subnet，v2 要 B_IP/32 |
| `MTU` | `1420` (`wg-client.conf.tpl:36`) | `1280`（留 QUIC 混淆余地，`strategy §4.1`） | Δ |
| `PresharedKey` | 有 | 有 | ✅ |
| `PersistentKeepalive` | `25` | — | ✅ |

### 是否已打包

**没有任何 zip/tar 打包逻辑**。`Grep "zip|tar.*-c|bundle"` 在 `user-management.sh` 和 `vpn.sh` 中零命中。管理员只能手工 `scp` 各文件。

---

## 2. v2 bundle 增量

| bundle 组件 | 当前 | v2 要求 (`strategy §13.5`) | 实现难度 |
|---|---|---|---|
| **`wg0.conf`** | 已生成；DNS=10.8.0.1 ✅；端口=51820 ❌；AllowedIPs 含 172.16.0.0/24 ❌ | 端口随机化 + AllowedIPs=`10.8.0.0/24,B_IP/32` + DNS=10.8.0.1 | **低**：改 `vpn.sh:910/924` 两行，加端口随机化（`shuf -i 30000-65000 -n 1` 持久化到 `/etc/bifrost.env`，`strategy §4.3`） |
| **`bifrost-root.crt`** | **零实现**：`Grep "root\.crt|caddy/pki|local CA"` 仅命中 `prompts/server-a-hardening-strategy.md` 自身 | 从 `/var/lib/caddy/.local/share/caddy/pki/authorities/local/root.crt` 导出（`strategy §3.3`） | **中**：依赖 §1 Caddy 切到 `tls internal` 完成；需在 `_ensure_user_dirs` 后注入 `cp` + 权限 644 |
| **`.npmrc` 片段** | **零实现** | `registry=https://npm.mirror.lan/`（v2 §3.1 镜像反代） | 低：纯文本片段 |
| **`daemon.json` 片段** | **零实现**（`common.sh:1295` 有 daemon.json 写入但不分发给员工） | `{"registry-mirrors":["https://docker.mirror.lan"]}` | 低 |
| **`.gitconfig` 片段** | **零实现** | `[url "https://gh.mirror.lan/"] insteadOf = https://github.com/` | 低 |
| **`README-onboarding.md`** | 当前 `<u>-guide.md`（`:1048-1244`）仅讲 VLESS+OPENAI_BASE_URL，**无 CA 三平台安装、无 mirror.lan 配置、无 DNS=10.8.0.1 强制说明** | 三平台 CA 安装 + 镜像配置 + 验证（`strategy §3.3 第 303-316 行脚本`） | 中：重写整段 Markdown 模板，三段 shell（Linux/macOS/Windows PowerShell） |
| **打包** | 零 | zip 一键下发 | 低：`zip -j <user>-bundle.zip ...` |

> **架构空洞**：v2 §13.5 设计的 `generate_client_bundle()` 函数**在 `user-management.sh` 中完全不存在**，注释里也没。`create_user` 当前仅在 `:721` 调一个 `_generate_user_guide`，与 v2 期望相去甚远。

---

## 3. CA 分发安全性（**最大风险点**）

`strategy §14` 已把"员工误装根证书在公司其他设备"列入风险表。但实际执行面比文档严重：

### 3.1 Caddy local CA 的硬性约束

- Caddy v2.x `tls internal` 签发的根证书**没有 CRL、没有 OCSP**。员工设备一旦 `update-ca-certificates` 装上，**操作系统永久信任**，除非 root CA 过期或被人工删除。
- 默认 root CA 有效期 **10 年**（Caddy 2.7+ 行为）。意味着：员工离职 → WG peer 删除 → 但其个人电脑/家庭 NAS 上的 `bifrost-root.crt` 依然有效 → 任何能伪造 `*.mirror.lan` 的攻击者（含离职员工自己）都能对其设备发起中间人，前提是攻击者能进入员工的 DNS 解析路径（咖啡馆 WiFi、家庭路由器 DHCP DNS）。

### 3.2 落地建议

| 措施 | 当前状态 | 推荐 |
|---|---|---|
| CA 私钥只在 A，永不下发 | 战略文档说明 `strategy §14`，**代码无强制** | `_generate_client_bundle` 严禁 `tar` 包含 `intermediates/` 私钥目录；只 `cp root.crt` |
| 根证书轮换周期 | **零设计** | 建议每 **6 个月** rotate（缩短 Caddy 默认 10 年）。需新增 `scripts/rotate-ca.sh`，触发 Caddy `caddy reload` + 全员重发 bundle |
| 离职吊销 | `disable_user` `:753-908` 只删 WG peer + Xray UUID + New API token，**完全不动 CA** | 必须文档化"已分发 CA 无法回收"，配合短周期 rotate |
| 设备绑定 | 无 | 入职时签字承诺"仅安装到工作设备"，结合 MDM（如可用）下发到指定机器 |

### 3.3 Caddy 不支持 CRL 的工程结论

→ **离职 = 必须 rotate 全员 CA**。否则离职员工的家用设备永远信任公司内网 PKI。这是 v2 §14 提到但未量化的 **隐性运维成本**：每次离职都要重发 bundle 给所有在职员工。对 N 人团队，每年人员流动 R%，CA 重签频次 ≈ `N * R%` 次/年。

---

## 4. 多平台兼容

### 4.1 桌面三平台脚本（`strategy §3.3:303-316`）

| 平台 | 命令 | 当前文档覆盖 |
|---|---|---|
| Linux | `cp /usr/local/share/ca-certificates/ && update-ca-certificates` | **无**（`CLIENT-SETUP.md` 0 命中 `ca-certificates`） |
| macOS | `security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain` | **无** |
| Windows | `Import-Certificate -FilePath ... -CertStoreLocation Cert:\LocalMachine\Root` | **无** |

`docs/CLIENT-SETUP.md` 和 `docs/VPN-SETUP.md` 中**零次** 命中 `certutil` / `update-ca-certificates` / `Import-Certificate` / `trustRoot`（已 Grep 验证）。

### 4.2 移动端盲区

- iOS / Android 在 v2 架构下**没有路径安装 root CA 给浏览器/系统**（iOS 需 Profile + 在"设置→关于本机→证书信任设置"二次启用；Android 14+ 用户 CA 仅应用级生效）。
- 现实问题：Claude Code mobile / Cursor mobile / ChatGPT 客户端通常**不信任用户 CA**（Android 应用默认不信任 user-installed CA，需 `network_security_config.xml`，员工无能力配置）。
- **结论**：v2 架构下，移动端只能通过 `OPENAI_BASE_URL=https://api.mirror.lan` 工作，但所有这些客户端走系统 TLS 栈 → **会因 CA 不被信任而失败**。除非员工手机 root/越狱，否则**移动端不可用**。当前 `<u>-guide.md:1131` 还在引导员工装 Shadowrocket 移动客户端，与 v2 架构冲突。

---

## 5. 离职流程

### 5.1 当前 disable_user（`user-management.sh:753-908`）

| 步骤 | 行号 | 状态 |
|---|---|---|
| 列出 active 用户 | `:762-772` | ✅ |
| 二次确认 | `:824` | ✅ |
| `_remove_xray_user` | `:835` | ✅ |
| `_force_revoke_vpn_user`（WG peer） | `:847` | ✅ |
| `_disable_api_token` | `:862` | ✅（先 PUT status=2，回退 DELETE） |
| 注册表 status → `disabled` | `:879-894` | ✅ |
| **CA 处理** | — | **❌ 零行代码** |
| `remove` 子命令 | — | **❌ 不存在**：`main:1343-1374` 只有 `create/disable/list/guide`，`disable` 是软禁用，**没有硬删除** |

### 5.2 缺失项

- 当前架构下"已分发 CA 设备列表"无台账。`<u>.credentials` 不记录"何时分发了 CA / 给哪台设备"。
- 没有定时任务提示管理员"距离上次 CA rotate 已 X 天"。
- 没有 `rotate_ca` / `regenerate_all_bundles` 子命令。

### 5.3 设计要求

新增 `user-management.sh rotate-ca` 子命令，流程：
1. `caddy reload` 触发新 root（或手动 `mv pki/authorities/local pki/authorities/local.old`）；
2. 对所有 `active` 用户调用 `generate_client_bundle`；
3. 通过 portal.mirror.lan 通知员工下载新 bundle；
4. T+7 天后旧 root 退役（Caddy 不再签发，但已签 leaf 仍有效到过期）。

---

## 6. 用户体验突变

### 6.1 步骤对比

| 阶段 | 旧流程（当前 docs/CLIENT-SETUP.md） | v2 新流程 |
|---|---|---|
| 1 | 装 WG client | 装 WG client |
| 2 | 导入 .conf + Activate | 导入 .conf（端口随机化后的） + Activate |
| 3 | `export OPENAI_BASE_URL=https://your-domain.com/v1` | **装 bifrost-root.crt 到系统信任库**（三平台命令不同） |
| 4 | `export OPENAI_API_KEY=sk-...` | 改 `~/.npmrc` 添加 `registry=https://npm.mirror.lan/` |
| 5 | done（2-3 步） | 改 `/etc/docker/daemon.json` 添加 `registry-mirrors` + `systemctl restart docker` |
| 6 | — | 改 `~/.gitconfig` 加 `insteadOf` |
| 7 | — | 改 DNS=10.8.0.1（WG 已推送，但本地 `systemd-resolved` 可能覆盖） |
| 8 | — | `export OPENAI_BASE_URL=https://api.mirror.lan` |
| 9 | — | 验证：`curl https://npm.mirror.lan/-/ping` `docker pull docker.mirror.lan/library/alpine` |

→ **从 3 步增至 9 步**。Docker 重启会断当前 dev 容器；CA 装错位置（用户级 vs 系统级）静默失败；员工 Mac 上 Docker Desktop 的 `daemon.json` 路径是 `~/.docker/daemon.json`，不是 `/etc/docker/`，文档若不分平台讲就是埋雷。

### 6.2 抗拒成本

- 当前 `docs/CLIENT-SETUP.md:230` "VPN 连不上"FAQ 已是高频问题；新流程会引入 "为什么 npm install 提示 SSL_ERROR_UNKNOWN_CA"、"docker pull 拒绝 unauthorized" 等全新失败模式。
- 员工无法自助排障：`npm config get registry` / `docker info | grep Registry` / `openssl s_client -connect npm.mirror.lan:443 -CAfile bifrost-root.crt` 这些诊断命令必须文档化，否则全压在管理员身上。

### 6.3 缓解

- bundle 中附 `bifrost-doctor.sh`：一键检查 CA 安装位置、`*.mirror.lan` DNS 是否解析到 10.8.0.1、TLS 链路是否通、镜像反代是否 200。
- portal.mirror.lan（v2 §3.2）放置 GIF 教程 + 错误码字典。

---

## 7. 文档改动估算

| 文件 | 当前状态 | 改动量 |
|---|---|---|
| `docs/CLIENT-SETUP.md`（256 行） | 全篇基于 v1 假设：`https://your-domain.com` + OPENAI_BASE_URL = 2 步 | **重写 60%**：新增"安装根证书"主章节（占 ~80 行），改写"配置 AI 工具"为 mirror.lan，加 docker/npm/git 三镜像章节 |
| `docs/VPN-SETUP.md`（412 行） | `:32` 写 `<Server-IP>:51820/udp`，`:152` 列 80/443/3000 这些公网端口 | **重写 30%**：删除 §144-170 的"Public ports"表（与 v2 公网零 HTTP/HTTPS 冲突），改写端口随机化说明；§32 把 51820 改为变量化 |
| `docs/USAGE.md`（局部审查） | `:36` 仍写 "端口 80, 443" | **改 10%**：Server A 端口表更新为"仅 UDP 高位 + SSH" |
| `docs/SERVER-A-STEALTH.md` | **不存在** | **新建**：v2 §13.6 要求；约 200 行（端口策略 / Caddy 内网 / nft 规则 / 备案规避证据） |
| `docs/CA-MANAGEMENT.md` | **不存在** | **新建**：CA 轮换周期、离职流程、应急吊销；约 150 行 |
| `scripts/user-management.sh` | 1376 行；`create_user` `:581-743` | **新增 ~250 行**：`_generate_client_bundle`、`_install_ca_helper` 三平台脚本生成、`rotate_ca` 子命令；改 `main:1343-1374` 加 `bundle / rotate-ca / regenerate-bundles` 子命令 |
| `configs/vpn/wg-client.conf.tpl` | 已支持模板变量 | **改 2 行**：MTU 1420→可配置；新增 `{{WG_PORT}}` 占位（当前直接写在 `vpn.sh:910`） |

### 培训成本

- 一次性：录制 3 个平台的 CA 安装视频（约 2 小时录制 + 编辑）。
- 持续：管理员每次员工新入职都要远程协助 30 分钟（验证 CA 安装 / 解释 docker daemon.json 平台差异 / 处理 systemd-resolved 覆盖 DNS 等）。N=20 人团队，年人员流动 30% → 年 ~3 小时 IT 支持时间。

---

## 总结

**v2 客户端 bundle 在代码层面是零实现**：`Grep` 验证 `user-management.sh` 与 `vpn.sh` 均无 `bundle / root.crt / mirror.lan / .npmrc / daemon.json` 任何一处命中，`docs/CLIENT-SETUP.md` 与 `docs/VPN-SETUP.md` 也对 Caddy local CA 三平台安装零覆盖。当前 `create_user` 只输出 Markdown 指南，与 v2 §13.5 设计完全脱节。最大隐性风险不是工程量（约 250 行 shell + 文档重写），而是 **Caddy local CA 无 CRL/OCSP** 导致离职员工设备永久信任内网 PKI，必须配套 **6 个月强制 CA rotate + 全员 bundle 重发** 才能闭环。移动端在 v2 架构下基本不可用（Android 用户 CA 默认不被应用信任），需在文档明示"移动端仅支持只读访问 portal"。员工入职步骤从 3 步突增到 9 步，必须提供 `bifrost-doctor.sh` 自检脚本 + portal 故障字典才能控制 IT 支持成本。
