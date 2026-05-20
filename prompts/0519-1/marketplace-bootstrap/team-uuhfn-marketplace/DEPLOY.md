# VPS 管理员部署清单 — team-uuhfn marketplace

> 给 VPS 管理员（ZRainbow）看的。团队成员只看 `团队-安装-教程.md`。

---

## 总目标

让团队成员一条命令拿到 claude-for-legal-ZH 的 12 个插件：

```
/plugin marketplace add https://files.uuhfn.cloud/git/bifrost-internal-plugins.git
/plugin install commercial-legal@team-uuhfn
```

全程不翻墙、走 VPS 中转。

---

## 前置依赖（按顺序确认）

| # | 依赖项 | 验证命令 | 没装怎么办 |
|---|---|---|---|
| 1 | Caddy + Verdaccio + files.uuhfn.cloud 跑起来 | 浏览器打开 https://files.uuhfn.cloud/ | 按 `prompts/0519-1/VPS-团队工具分发-教程.md` |
| 2 | Git for Windows | `git --version` | https://git-scm.com/download/win |
| 3 | files.uuhfn.cloud Caddyfile 含 `/git/*` handler | 见 Caddyfile-additions.txt 替换块 | 部署 claude-for-legal-mirror（步骤 A） |
| 4 | claude-for-legal-ZH 镜像 | `dir C:\caddy\git\claude-for-legal-ZH.git` | 部署 claude-for-legal-mirror（步骤 A） |

---

## 部署步骤

### 步骤 A. 先部署 claude-for-legal-ZH 上游镜像（如果还没做）

按 `prompts/0519-1/claude-for-legal-mirror/DEPLOY.md` 完整走一遍。最终验证：

```powershell
git ls-remote https://files.uuhfn.cloud/git/claude-for-legal-ZH.git
# 应输出一行 commit SHA + refs/heads/main
```

⚠️ **本步骤必须先成功**。否则下面的 marketplace.json 里 `git-subdir` source
指向的 URL 会 404，团队成员 `/plugin install` 会失败。

---

### 步骤 B. 上传 team-uuhfn-marketplace 目录到 VPS

把整个目录（含 `.claude-plugin/marketplace.json`、`README.md`、本脚本等）传到 VPS：

```
C:\caddy\scripts\team-uuhfn-marketplace\
├── .claude-plugin\
│   └── marketplace.json
├── README.md
├── DEPLOY.md
├── setup-marketplace-vps.ps1
└── 团队-安装-教程.md
```

传输方式任选（rsync / scp / 远程桌面拖拽 / 自建临时 share）。

---

### 步骤 C. 跑部署脚本

以**管理员身份**打开 PowerShell：

```powershell
cd C:\caddy\scripts\team-uuhfn-marketplace
PowerShell -ExecutionPolicy Bypass -File .\setup-marketplace-vps.ps1
```

脚本会：

1. 校验 git/upstream-mirror/marketplace.json
2. 在 `C:\caddy\git\bifrost-internal-plugins.git` 初始化 bare repo
3. 把当前目录全部内容打成一个 commit push 进去
4. `update-server-info` 启用 dumb HTTP
5. 关闭 receive-pack（禁推）
6. 远端 probe 验证

成功后末尾会输出：

```
=== SETUP COMPLETE ===
Marketplace bare repo : C:\caddy\git\bifrost-internal-plugins.git
Public URL            : https://files.uuhfn.cloud/git/bifrost-internal-plugins.git
```

---

### 步骤 D. 自测三链路

**链路 1：marketplace bare repo 暴露正常**

```powershell
curl.exe -I https://files.uuhfn.cloud/git/bifrost-internal-plugins.git/info/refs?service=git-upload-pack
```

应返回 `HTTP/2 200` + `content-type: application/x-git-upload-pack-advertisement`。

**链路 2：marketplace.json 内嵌可读**

```powershell
# 拉一个临时 clone 看 catalog 是否完整
$tmp = "$env:TEMP\marketplace-test"
git clone https://files.uuhfn.cloud/git/bifrost-internal-plugins.git $tmp
Get-Content "$tmp\.claude-plugin\marketplace.json" | Select-Object -First 20
Remove-Item -Recurse -Force $tmp
```

应看到 `"name": "team-uuhfn"` + 12 个 plugin 条目。

**链路 3：git-subdir 目标 sparse clone 可达**

```powershell
$tmp = "$env:TEMP\subdir-test"
git clone --depth 1 --filter=blob:none --sparse https://files.uuhfn.cloud/git/claude-for-legal-ZH.git $tmp
cd $tmp
git sparse-checkout set commercial-legal
dir commercial-legal
cd ..
Remove-Item -Recurse -Force $tmp
```

应看到 `commercial-legal/` 下有 `.claude-plugin/plugin.json` 等文件。

⚠️ 这一步如果失败 → claude-for-legal-mirror 没装好，回步骤 A。

---

### 步骤 E. 在团队成员机器上端到端验证

挑一台干净 Windows / macOS 机器（**或自己的笔记本，不在 VPS 上**），跑：

```
# Claude Code 内：
/plugin marketplace add https://files.uuhfn.cloud/git/bifrost-internal-plugins.git
```

应输出：

```
✓ Added marketplace 'team-uuhfn' (12 plugins)
```

然后：

```
/plugin install commercial-legal@team-uuhfn
```

应输出：

```
✓ Installed commercial-legal@team-uuhfn
```

打开新会话，`/help` 能看到 commercial-legal 提供的命令 → 端到端通。

---

### 步骤 F. 公告团队

把 `团队-安装-教程.md` 上传到 `C:\caddy\dist\docs\`（如不存在则 `mkdir`）：

```powershell
mkdir C:\caddy\dist\docs -Force
Copy-Item 'C:\caddy\scripts\team-uuhfn-marketplace\团队-安装-教程.md' `
          'C:\caddy\dist\docs\'
```

团队访问：`https://files.uuhfn.cloud/docs/团队-安装-教程.md`。

---

## 运维操作速查

| 想做什么 | 命令 |
|---|---|
| 重新 push marketplace（改了 marketplace.json 后） | 重跑 `setup-marketplace-vps.ps1`（force push 幂等） |
| 检查 bare repo 大小 | `(Get-ChildItem 'C:\caddy\git\bifrost-internal-plugins.git' -Recurse \| Measure-Object Length -Sum).Sum / 1KB` |
| 强制团队刷新本地缓存 | 团队跑 `/plugin marketplace update team-uuhfn` |
| 完全卸载 marketplace | 删 `C:\caddy\git\bifrost-internal-plugins.git`；通知团队跑 `/plugin marketplace remove team-uuhfn` |
| 查 Caddy 访问日志 | `Get-Content C:\caddy\logs\files-access.log -Tail 50` |

---

## 添加内部插件流程（未来扩展）

1. 在工作机本地 `team-uuhfn-marketplace/` 下建 `plugins/<my-plugin>/`，含
   `.claude-plugin/plugin.json`、`README.md`、skills/agents/hooks 等
2. 编辑 `.claude-plugin/marketplace.json`，`plugins[]` 追加：

   ```json
   {
     "name": "my-plugin",
     "source": "./plugins/my-plugin",
     "description": "...",
     "version": "0.1.0",
     "author": { "name": "Bifrost Team" }
   }
   ```
3. 上传到 VPS 同一路径，重跑 `setup-marketplace-vps.ps1`
4. 通知团队 `/plugin marketplace update team-uuhfn` 拉新版

---

## 风险与注意

| 风险 | 缓解 |
|---|---|
| Caddy `/git/*` handler 没 401/IP 白名单 = 公网任何人可访问 marketplace catalog | 如内部插件含敏感信息，加 Caddy basicauth/IP allowlist；当前 claude-for-legal-ZH 是公开 Apache-2.0 不敏感 |
| force-push 覆盖团队成员本地缓存 | Claude Code `marketplace update` 会自动 reset to remote；如团队报"安装版本回退"是正常行为 |
| git-subdir 在客户端 Git 版本过旧时不支持 sparse checkout | Claude Code 内置 git 支持，本机外部 git 仅在手工 clone 测试时需要 ≥ 2.25 |
| upstream mirror sync 失败导致 stale catalog | 团队 install 拿到的是 mirror 当前 HEAD；定时任务失败时手动跑 `Start-ScheduledTask -TaskName claude-for-legal-sync` |

---

**部署完成确认清单**：

- [ ] 步骤 A：`git ls-remote https://files.uuhfn.cloud/git/claude-for-legal-ZH.git` 返回 SHA
- [ ] 步骤 B：marketplace 源目录在 `C:\caddy\scripts\team-uuhfn-marketplace\`
- [ ] 步骤 C：`setup-marketplace-vps.ps1` 末尾输出 SETUP COMPLETE
- [ ] 步骤 D 三链路全 OK
- [ ] 步骤 E 团队成员机器端到端 install 成功
- [ ] 步骤 F 团队教程已上传到 `https://files.uuhfn.cloud/docs/`
- [ ] 团队公告群已发

✅ 全部打钩 → 完工。
