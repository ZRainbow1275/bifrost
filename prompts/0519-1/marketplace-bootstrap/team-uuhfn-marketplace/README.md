# team-uuhfn — Claude Code 团队插件市场（Windows VPS 托管）

> 部署在 `uuhfn.cloud` Windows VPS 上的 Claude Code plugin marketplace 聚合器。
> 团队成员只需 add 一个 marketplace URL，即可看到所有插件。

---

## 这是什么

一个 **marketplace 仓库**（不是 plugin 本体）。`.claude-plugin/marketplace.json`
通过 `git-subdir` source 引用 VPS 上另一个仓库 `claude-for-legal-ZH.git` 的 12
个子目录，把上游 [CSlawyer1985/claude-for-legal-ZH](https://github.com/CSlawyer1985/claude-for-legal-ZH)
的 12 个法律插件聚合进来，并预留位置给未来的团队内部插件。

**架构**：

```
团队成员 Claude Code 客户端
        │
        │  /plugin marketplace add https://files.uuhfn.cloud/git/bifrost-internal-plugins.git
        │  /plugin install commercial-legal@team-uuhfn
        │
        ▼
   Windows VPS (uuhfn.cloud)
   ├─ Caddy 443 → files.uuhfn.cloud
   ├─ C:\caddy\git\bifrost-internal-plugins.git   ← 本仓库（marketplace catalog）
   │     └─ .claude-plugin/marketplace.json       ← 列 12 个 git-subdir 引用
   └─ C:\caddy\git\claude-for-legal-ZH.git        ← 上游镜像（每日 02:00 同步）
         ├─ commercial-legal/      ← git-subdir sparse clone 目标
         ├─ corporate-legal/
         ├─ ...12 个子目录
         └─ .claude-plugin/marketplace.json (上游自带，本市场不使用)
```

**为什么用 git-subdir 而非 url 整仓**：
Claude Code 客户端按 `git-subdir` 走 sparse partial clone，每个 plugin 只拉自己那一个子目录，
不会把 17MB 完整 repo 重复拉 12 遍。

**为什么不让团队直接 add 上游 GitHub URL**：
- 国内访问 github.com 不稳，避翻墙是核心诉求
- 上游 marketplace.json 用相对路径 `source: "./commercial-legal"`，强制把 ref 锁定到上游 repo
- 本市场用 git-subdir 把 source 重定向到 VPS 镜像，避翻墙 + 未来可加内部插件聚合

---

## 文件结构

```
team-uuhfn-marketplace/
├── .claude-plugin/
│   └── marketplace.json     # 12 plugin 条目，全部 git-subdir → VPS 镜像
├── README.md                 # 本文件
├── DEPLOY.md                 # VPS 管理员部署指引
├── setup-marketplace-vps.ps1 # VPS 一次性部署脚本
└── 团队-安装-教程.md         # 团队成员一键添加 marketplace 教程
```

---

## 上游许可证合规

claude-for-legal-ZH 是 **Apache-2.0** 协议，允许镜像分发。
本 marketplace **不**修改上游插件代码，仅在 marketplace.json 层面做 source 重定向。
上游每个插件子目录内的 LICENSE / NOTICE 在 sparse clone 时随插件一起下发到客户端。

VPS 上的 `claude-for-legal-ZH.git` 镜像通过 `git remote update` 每日同步上游
HEAD，不做任何代码改动。同步脚本：`prompts/0519-1/claude-for-legal-mirror/sync-claude-for-legal.ps1`。

---

## 未来扩展（团队内部插件）

要往本 marketplace 里加内部插件，编辑 `.claude-plugin/marketplace.json`，
在 `plugins[]` 数组追加：

```json
{
  "name": "my-internal-plugin",
  "source": "./plugins/my-internal-plugin",
  "description": "...",
  "version": "0.1.0",
  "author": { "name": "Bifrost Team" }
}
```

然后把插件目录放进本仓库的 `plugins/<name>/` 下（含 `.claude-plugin/plugin.json`），
推送到 VPS bare repo 即可。Claude Code 客户端跑 `/plugin marketplace update team-uuhfn`
就能看到新插件。

注意：相对路径 source 要求**本市场仓库**本身被 sparse 整体 clone 一次，因此团队
add 的 marketplace URL 必须是 git URL 而非裸 JSON URL（已经满足，本市场只通过
`https://files.uuhfn.cloud/git/bifrost-internal-plugins.git` 暴露）。

---

**作者**: ZRainbow
**最后更新**: 2026-05-20
**协议**: 本 marketplace catalog 文件（marketplace.json/README）= MIT；引用的 claude-for-legal-ZH 插件 = Apache-2.0（保留上游 LICENSE）
