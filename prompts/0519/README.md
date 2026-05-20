# 2026-05-19 Server A 加固 v2 战略修订

> 上游战略：[`../server-a-hardening-strategy.md`](../server-a-hardening-strategy.md)（v2.0，1083 行）
> Trellis 任务：`.trellis/tasks/05-19-server-a-hardening-v2/`

## 交付物

| 文件 | 用途 |
|---|---|
| [`strategy-revision-plan.md`](strategy-revision-plan.md) | **主规划文档**：v2 决策矩阵（采纳/延后/否决）、替代方案 X/Y/Z 对比、路径冲突 P0/P1/P2、PR 拆分、风险矩阵、开放问题 |
| [`research/01-server-a-inventory.md`](research/01-server-a-inventory.md) | Server A 公网/Caddyfile/New API 冲突清单（P0 ×10） |
| [`research/02-network-stack.md`](research/02-network-stack.md) | 网络栈（WG/SSH/nftables/fail2ban）现状审查 |
| [`research/03-proxy-stack.md`](research/03-proxy-stack.md) | 代理栈（Mihomo/Xray/anti-dpi）现状审查 |
| [`research/04-user-bundle.md`](research/04-user-bundle.md) | 员工接入流程 + CA 分发风险 |
| [`research/05-server-b-impact.md`](research/05-server-b-impact.md) | Server B 承接能力 + 镜像服务选型缺口 |
| [`research/06-strategic-critique.md`](research/06-strategic-critique.md) | 战略前提批判 + 9877b12 矛盾 + 方案 X 论证 |

## 一句话结论

**不建议全盘采纳 v2**。
v2 与 3 天前合并的 `9877b12`（460 行 IP HTTPS）公开矛盾，
对方案 X（腾讯云香港 ¥24/月免备案）完全沉默，
强制 VPN-only + 根 CA + awg 客户端与 README "一键部署、零运维" 产品定位严重冲突。

详细决策矩阵与 PR 拆分见 [`strategy-revision-plan.md`](strategy-revision-plan.md)。

## 审查方法

- 6 个并行 agent 批判审查
- WebFetch / WebSearch 实证（腾讯云 ICP 文档 / V2EX 1082505 / RFA 2026-04 / Let's Encrypt 6-day IP cert GA / 2026 GFW 现状）
- `git show 9877b12 04be5ac f90a229` 看实际改动
- Grep / Read 扫描 13386 行核心脚本（server-a / server-b / vpn / security / user-management / anti-dpi / mihomo）
- 所有指控附 `file:line` 引用

## 必须用户决策的开放问题

| Q# | 问题 |
|---|---|
| Q1 | 接受方案 X（A 改腾讯云香港 Lighthouse ¥24/月免备案）吗？ |
| Q2 | `9877b12` IP HTTPS 460 行代码：保留 legacy / 删除 / 还原主路径？ |
| Q3 | 强制 VPN-only 对非技术员工（PM/财务/HR）覆盖率怎么定？ |
| Q4 | 接受产品定位从"一键部署"改为"企业内网零信任 PKI 改造"吗？ |
| Q5 | B 端 8C16G 月 $80-160 客户能接受吗？ |
| Q6 | vanilla WG 在腾讯云的 4 周实测预算谁出？ |
| Q7 | 现网用 domain/cloudflare-origin/ip 模式的生产用户怎么迁移？ |
