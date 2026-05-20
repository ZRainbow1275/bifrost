# 网络栈现状 vs v2 战略审查

> 审查对象：Bifrost 项目网络栈（WireGuard / SSH / 防火墙 / fail2ban）
> 对照基线：`prompts/server-a-hardening-strategy.md` v2（§2/§4/§5/§8）
> 审查日期：2026-05-18

---

## 1. WireGuard 现状

### 1.1 ListenPort 实现

当前实现是**硬编码常量 51820**，无任何随机化或环境变量覆盖：

- `scripts/vpn.sh:51` —— `readonly WG_PORT=51820`
- `scripts/vpn.sh:1199` —— `ListenPort = ${WG_PORT}`（写入 `/etc/wireguard/wg0.conf`）
- `scripts/vpn.sh:910` —— `server_endpoint="${PUBLIC_IP}:${WG_PORT}"`（用于客户端 Endpoint）
- `scripts/security.sh:658` —— ufw 同样硬编码 `ufw allow 51820/udp comment "WireGuard VPN"`
- `scripts/security.sh:727` —— firewalld 同样硬编码 `--add-port=51820/udp`
- `configs/network/iptables-rules.sh:272` —— `iptables -A INPUT -p udp --dport 51820 -j ACCEPT`
- `configs/vpn/iptables-vpn.sh:191` —— 同样硬编码 51820

**51820 是 WireGuard 的官方默认端口**——这是被全球 DPI 系统（含腾讯云）标记的"已知 VPN 端口"，是 v2 §4.1 列入"必须避开"的黑名单之首。

### 1.2 客户端配置模板字段

`configs/vpn/wg-client.conf.tpl` 字段齐全（PrivateKey/Address/DNS/MTU/PublicKey/PresharedKey/Endpoint/AllowedIPs/PersistentKeepalive），MTU=1420（默认）。**但占位变量未含 `WG_PORT`**：`Endpoint = {{SERVER_ENDPOINT}}` 把 IP+Port 当一个整体字符串注入（`vpn.sh:910` 已拼好），故现行模板无端口随机化能力。

### 1.3 v2 差距清单

| v2 要求 | 现状 | 差距 |
|---|---|---|
| 端口范围 30000-65000 随机 | 固定 51820 | 必须改 |
| 持久化到 `/etc/bifrost.env` | 仅运行时 readonly 常量 | 需新增持久化文件 |
| 安装时 `shuf -i 30000-65000 -n 1` | 无 | 需新增逻辑 |
| 客户端 bundle 自动读取 | 静态拼接 | 需联动模板渲染 |
| MTU=1280（v2 §4.1 推荐） | 1420 | 留余地给 QUIC 混淆封装需调低 |
| PSK 启用 | `vpn.sh:1225` 已支持 | OK |
| PostUp 加载 nftables 规则 | PostUp 仍写 `iptables -A FORWARD ... MASQUERADE`（`vpn.sh:1202-1203`） | 与 v2 §5 的 nftables 替换冲突 |

**结论**：WG 端口随机化是**最高优先级整改项**，影响面横跨 `vpn.sh / security.sh / iptables-vpn.sh / iptables-rules.sh / firezone-compose.yml` 五处硬编码。

---

## 2. AmneziaWG 集成可行性

### 2.1 工具链支持现状

代码库**零** AmneziaWG 痕迹（Grep `awg|amnezia` 仅命中战略文档本身）。`vpn.sh:185-220` 只装 `wireguard wireguard-tools`，无 `awg-quick` 安装路径。

### 2.2 客户端兼容性问题

- AmneziaWG 协议**与原版 WG 互不兼容**（首包加 Junk/H1-H4 后，普通 wireguard-tools 会丢包）
- 员工要么全装 Amnezia GUI（Android/iOS/Win/macOS/Linux），要么坚持普通 WG 客户端
- 一旦启用 AWG，**原 wg-quick 客户端立即失能**——不存在"双轨兼容"

### 2.3 推荐路径

战略 v2 §4.2 提出 Level 1→3 渐进，建议落地策略：

1. **首选 Level 1（仅高位随机端口）**——一周内可上线，零工具链改动
2. **后置 Level 3（AWG）**——需 fork 一个 `BIFROST_WG_OBFUSCATION=amneziawg` 开关分支，模板 `configs/vpn/awg-template.conf` + 客户端 bundle 同步输出 AWG 配置
3. **不建议双轨**：维护成本翻倍，员工设备生态会分化

---

## 3. SSH 双通道方案评估

### 3.1 当前 SSH 端口策略

`scripts/security.sh:367` 调用 `_generate_random_port()`（`security.sh:130`），生成范围 **10000-65000** 单一随机端口。比 v2 要求的"60022 公网 + 22 内网"差距大：

- 当前是**单实例 sshd**，单端口绑全部接口
- `_set_sshd_option "Port" "${ssh_port}"`（`security.sh:451`）只写一行 Port，无 ListenAddress / Match 限制
- 无任何 IP allowlist（仅 fail2ban 跑事后封禁）

### 3.2 双通道落地选项

**选项 A：单 sshd + 双 ListenAddress + Match Address**（推荐）

```
Port 60022
ListenAddress 0.0.0.0:60022
ListenAddress 10.8.0.1:22

Match Address 10.8.0.0/24
    PasswordAuthentication no
    AuthenticationMethods publickey
Match Address !10.8.0.0/24
    AllowUsers admin@1.2.3.4,admin@5.6.7.8
```

优点：单进程、单 systemd unit，配置可维护。
缺点：sshd_config 复杂度上升，Match 块语法易写错。

**选项 B：两个 sshd 实例**

- `sshd@public.service` 监听 60022（公网 + IP allowlist）
- `sshd@internal.service` 监听 wg0:22
- 缺点：维护两份配置、两份 systemd unit，更新滞后风险

战略 v2 §2.1 隐含选项 A（"`sshd + admin IP allowlist`"单条目）。建议落地用 A。

### 3.3 admin IP allowlist 漂移问题

当前实现无任何 allowlist；v2 §5 nftables 模板设 `set ssh_admin_allow { ip 1.2.3.4, 5.6.7.8 }`。**这是高风险设计**：

- 管理员家庭/办公网 IP 动态分配，allowlist 一旦失效就**完全失联**
- 需要配套：
  1. 备份接入通道（VPS Console / 云厂商带外控制台 / 紧急 PSK 静态 IP）
  2. 自助更新接口（员工门户 portal.mirror.lan 提供 "更新管理员 IP" 表单，自身要 VPN 内访问—鸡生蛋问题）
  3. DDNS + nftables `set` 周期 reload（cron 每 5 分钟解析域名注入）

**建议**：v2 落地时同步交付"`scripts/admin-allowlist-update.sh`"+ 文档强制要求**双管理员 IP + 1 个 console 应急通道**。

---

## 4. 防火墙迁移：iptables → nftables

### 4.1 当前栈

代码库**完全无 nftables**（Grep `nft|nftables|table inet` 仅在战略文档内命中）。三个并存的防火墙后端：

- **UFW**（`security.sh:628-679` `_setup_firewall_ufw`）——`ufw default deny incoming + allow outgoing`，policy 模式与 v2 接近但语义层级低
- **firewalld**（`security.sh:686-738` `_setup_firewall_firewalld`）——`--set-target=DROP`
- **裸 iptables**（`configs/network/iptables-rules.sh` + `configs/vpn/iptables-vpn.sh`）—— 显式 `iptables -P INPUT DROP`，自带 `AI_GW_LOG_DROP` 链

更关键的是**冲突逻辑**：`iptables-rules.sh:178-181` 启动时主动 `ufw disable`——三层栈互相抢占。`detect_conflicting_firewall_owners()`（`iptables-rules.sh:81-95`）只检测 VPN_INPUT/VPN_FORWARD 链冲突，但不识别 UFW 残留规则。

### 4.2 Mihomo TPROXY 兼容性

**代码库目前没有任何 TPROXY 规则**。`scripts/mihomo.sh` Grep 不到 `TPROXY|tproxy|fwmark`。战略 v2 §5 `chain prerouting_mangle` 是空模板，留待 Mihomo 启动时 PostUp 注入——这是**未实现的设计**。需新增：

1. `scripts/mihomo.sh` 加 `setup_tproxy_nft()`，注入 `mark 0x1 tproxy to :7895`
2. mihomo systemd unit `ExecStartPre=/usr/sbin/nft -f /etc/nftables.d/mihomo-tproxy.nft`
3. `ExecStopPost=/usr/sbin/nft delete table inet mihomo`

### 4.3 迁移破坏面

| 破坏点 | 影响 | 缓解 |
|---|---|---|
| 现网用户 ufw 自定义规则 | 升级即丢 | 升级脚本先 `ufw status numbered > backup`，提示用户保留 |
| `configs/network/iptables-rules.sh` 服务化 | 用户已 enable 的 systemd unit 失效 | 提供 `bifrost migrate-firewall` 一键迁移 |
| Docker 链（`AI_GW_LOG_DROP` 处理 docker0） | 容器网络中断 | nftables 需手动复刻 `iifname "docker0" jump docker_chain` |
| firewalld（CentOS/RHEL 用户） | nftables 后端兼容性更好 | 实际 firewalld 默认就是 nftables 后端，直接卸载即可 |

**建议**：v2 落地分两阶段：

- **Phase 1**：在 `install.sh` 选项里增加 `BIFROST_FIREWALL=nftables`（新装默认），保留 ufw/iptables 作为升级期 fallback
- **Phase 2**：发版 N+2 后强制 nftables，旧栈打 `deprecated` 警告

---

## 5. fail2ban 缩容评估

### 5.1 当前 jail 列表

`configs/fail2ban/jail.local` 与 `security.sh:841-899` 双源生成 jail 配置（**两处不一致是 bug 隐患**）：

| jail | 状态 | logpath | 作用 |
|---|---|---|---|
| `[sshd]` | enabled | `/var/log/auth.log` | OK，v2 §8 保留 |
| `[caddy-auth]` | **enabled** | `/var/log/caddy/access.log` | **v2 要求关闭**（公网无 Caddy） |
| `[caddy-botsearch]` | **enabled** | `/var/log/caddy/access.log` | **v2 要求关闭** |
| `[recidive]` | enabled | `/var/log/fail2ban.log` | 可保留（防 SSH 长期暴破） |
| `[wireguard]` | 不存在 | — | 与 v2 一致（WG 无登录概念） |

### 5.2 删除 Caddy jail 后的审计替代

战略 v2 §3.1 把 Caddy 移入 wg0:443，理论上**只有 VPN 内部员工能访问**，bot 扫描归零。但应保留：

- Caddy 自身 JSON access log（`vpn_required` snippet abort 仍会留行）
- 周期审计：`nft list set inet bifrost ssh_rate`（meter 表）+ `journalctl -u sshd` + Caddy log 聚合
- 替换 fail2ban-caddy 的 v2 等价物：**Caddy `(vpn_required)` snippet 直接 abort**（战略 v2 §3.1 第 144-150 行）——绕开 fail2ban 链路

### 5.3 内存差距

战略 v2 §9 给 fail2ban 预算 30MB。当前实测启用 3 jail（sshd + 2 caddy）+ recidive，运行 RSS 约 40-50MB。缩成单 jail 后可降至 25MB，**释放 ~25MB**。

---

## 6. Firezone / Headscale 路径冲突

### 6.1 现状

代码库**三套 VPN 后端并存**：

- `scripts/vpn.sh:185-220` `_vpn_install_wireguard()` —— 裸 WG
- `scripts/vpn.sh:478-...` `_vpn_deploy_firezone()` —— Firezone v0.7.36（Docker Compose）
- `scripts/vpn.sh:600-770` Headscale 安装
- 通过 `_vpn_save_state "VPN_TYPE" "firezone|headscale|wireguard"`（`vpn.sh:599 / 766 / 1053`）三选一

`configs/vpn/firezone-compose.yml` 与 `configs/vpn/headscale-config.yaml` 均存在完整模板。

### 6.2 与 v2 的冲突

战略 v2 §2/§4/§7 假设**裸 WireGuard**（无 Firezone Admin UI、无 Headscale 控制平面），原因：

1. Firezone v0.7.x EoL（2024 中已 EoL，文件注释也承认）
2. Firezone v1.x 架构变了，本仓库的 compose 不兼容
3. Firezone admin UI 监听 13000，Headscale 监听 8080——**两者都要公网或 wg0 入口**，与"公网只开 1 UDP + 1 TCP SSH"矛盾
4. v2 §6 用 Mihomo external-controller 10.8.0.1:9090 作管理面，已经替代 Headscale metrics 角色

### 6.3 处置建议

| 选项 | 收益 | 代价 |
|---|---|---|
| **彻底淘汰** Firezone+Headscale（推荐） | 删 ~1200 行代码 + 2 个模板；架构清晰 | 失去 Web GUI（员工自助走 portal.mirror.lan 表单 + manage API 替代） |
| 保留作为可选 profile | 兼容现有部署 | 持续维护负担，v0.7.x 已无安全补丁 |
| 仅保留 Headscale | Tailscale 生态 mesh 价值 | 仍需 Web 端口暴露 |

v2 明确建议路径：**在 §18 "项目方建议"加入 `BIFROST_SERVER_A_PROFILE=private-internal` 时自动屏蔽 Firezone/Headscale 安装路径**。代码层面应在 `vpn.sh` 顶部读取 profile 后早返回 `_vpn_install_wireguard()`，跳过另两个安装函数的入口。

---

## 7. 风险与替代

### 7.1 WG 高位 UDP 被腾讯云风控

战略 v2 §14 已列出"VPN 慢/丢包"风险。补充批判：

- 腾讯云对 **UDP 突发流量**有黑盒 QoS（不是 DPI，而是带宽抑制），高位端口在 BT 客户端用户中常见画像，可能误伤
- WG **握手包大小固定 148 字节**，DPI 指纹依然可识别（即使 Level 1 高位端口）—— 这是 v2 §4.2 列出 AWG 的根本动因
- 实测建议：部署后 24h 跑 `iperf3 -u -b 100M` 上下行测速，与 TCP 速率比对，若 UDP < 30% TCP 则风控已触发

### 7.2 备用方案矩阵

| 方案 | 触发条件 | 代价 |
|---|---|---|
| 端口跳变（同一 VPS 多 WG 实例轮换） | 单端口被画像 | 客户端需重连 |
| **udp2raw**（包装成假 TCP/443） | 高位 UDP 全死 | 10-15% 性能损失，多一个进程 |
| Cloudflare WARP+ / Argo Tunnel | 腾讯云出口完全失能 | 依赖外网，可能被 GFW 拖累 |
| **换云厂商**（Vultr/Hetzner/Linode 国内出口） | 腾讯云政策升级 | 迁移成本 + 备案问题转移 |
| 加密 ICMP（icmptunnel） | 极端场景 | 性能极差，仅作 fallback |

**v2 文档对此考虑充分（§14 表格 + §18 §6 cloud-detect.sh）**，但代码侧**尚无 `scripts/cloud-detect.sh`**——需新增。

---

## 8. 总结：现状 vs v2 整体差距评分

| 维度 | 现状成熟度 | v2 目标 | 差距 |
|---|---|---|---|
| WG 端口随机化 | 0 / 10（硬编码 51820） | 10 | **极大** |
| AmneziaWG | 0 / 10 | 8（Level 1 启用，Level 3 待启用） | 大 |
| SSH 双通道 | 3 / 10（仅单端口随机） | 9 | 大 |
| nftables 替换 | 0 / 10（三套旧栈共存） | 10 | **极大** |
| fail2ban 缩容 | 4 / 10（3 jail） | 9（仅 sshd） | 中 |
| Firezone/Headscale 淘汰 | 2 / 10（三栈并存） | 10（仅裸 WG） | 大 |
| Mihomo TPROXY 集成 | 1 / 10（无规则） | 9 | **极大** |
| admin allowlist 机制 | 0 / 10 | 8 | 大 |

**优先级建议（落地顺序）**：

1. WG 端口随机化 + 持久化到 `/etc/bifrost.env`（影响 5 个文件，1 天）
2. nftables 模板上线 + 三栈兼容期开关（影响 install/security/vpn 三脚本，3 天）
3. SSH 双通道 sshd_config Match 块（影响 security.sh 单文件，1 天）
4. fail2ban 缩容至 sshd jail（影响 jail.local + security.sh，0.5 天）
5. Mihomo TPROXY nft 注入（影响 mihomo.sh + 新增 nft 模板，2 天）
6. Firezone/Headscale 标记 deprecated（影响 vpn.sh，0.5 天）
7. AmneziaWG 可选分支（影响 vpn.sh + 新模板，3 天）

总计约 **11 工作日**的 v2 完整落地工作量。当前代码库与 v2 战略目标的整体匹配度约 **15-20%**，属于"几乎全部要重写网络栈核心"的状态。
