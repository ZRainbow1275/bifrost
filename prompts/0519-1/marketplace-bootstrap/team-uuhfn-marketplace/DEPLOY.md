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

以**管理员身份**打开 PowerShell:

```powershell
cd C:\caddy\scripts\team-uuhfn-marketplace
PowerShell -ExecutionPolicy Bypass -File .\setup-marketplace-vps.ps1
```

脚本会:

1. 校验 git / upstream-mirror / marketplace.json
2. 在 `C:\caddy\git\bifrost-internal-plugins.git` 初始化 bare repo
3. 把当前目录全部内容打成一个 commit push 进去
4. `git symbolic-ref HEAD refs/heads/main` (修 init --bare 默认 HEAD = master)
5. `update-server-info` 启用 dumb HTTP
6. 关闭 receive-pack (禁推)
7. 远端 probe 验证 (Win PowerShell 5.1 会 warn `SkipHttpErrorCheck` 不识别 → 无害,
   是 PowerShell 7+ 才有的参数, 跳过即可)

成功后末尾输出:

```
=== SETUP COMPLETE ===
Marketplace bare repo : C:\caddy\git\bifrost-internal-plugins.git
Public URL            : https://files.uuhfn.cloud/git/bifrost-internal-plugins.git
```

#### C 步骤已知坑速查

| 报错 | 根因 | 修复 |
|---|---|---|
| `The string is missing the terminator: '.` | Win PS 5.1 按 ANSI/GBK 读 UTF-8 .ps1, 中文 Write-Host 乱码后引号配对崩 | 已在脚本里全 ASCII Write-Host 化; 注释中文无影响 (parser 跳过注释) |
| `git : To <repo> ... NativeCommandError` 但 `$LASTEXITCODE = 0` | `$ErrorActionPreference=Stop` + `2>&1` 把 git stderr 进度信息当 Exception | 脚本已改 `Continue`, 改靠 `$LASTEXITCODE` 判定 |
| `bare repo exists, will force-update refs` 然后中断 | 脚本幂等, 此提示正常, 不是错 | 继续看后面 step |

如果 Write-Host 输出仍乱码 (`é‡è·‘æœ¬è„šæœ¬`)、但 parser 不报错 → 装 PowerShell 7
(`winget install Microsoft.PowerShell`) 用 `pwsh` 重跑即可。

---

### 步骤 D. 自测四链路 (含 HEAD 校验)

> ⚠️ **重要**: Caddyfile 的 `/git/*` handler **不要**给 `*/info/refs` 设
> `Content-Type: application/x-git-upload-pack-advertisement` — 那会让 git 客户端
> 走 smart HTTP 协议而 server 只能提供 dumb HTTP 静态文件,导致
> `fatal: the remote end hung up unexpectedly`。让 Caddy 用默认 mime guess 即可,
> git 自动 fallback dumb HTTP。

**链路 0(前置): bare repo HEAD 指向正确分支**

`git init --bare` 默认 HEAD = `refs/heads/master`,但 setup 脚本 push 的是 `main`,
若不修正 HEAD,clone 时会 `warning: remote HEAD refers to nonexistent ref, unable to checkout`。

```powershell
Get-Content C:\caddy\git\bifrost-internal-plugins.git\HEAD
# 期望: ref: refs/heads/main
# 如果是 master:
git -C C:\caddy\git\bifrost-internal-plugins.git symbolic-ref HEAD refs/heads/main
git -C C:\caddy\git\bifrost-internal-plugins.git --bare update-server-info
```

`setup-marketplace-vps.ps1` step 7 已包含此修正; 历史已部署版本需手动跑上面两行。

**链路 1: marketplace bare repo 暴露正常**

```powershell
curl.exe -I "https://files.uuhfn.cloud/git/bifrost-internal-plugins.git/info/refs?service=git-upload-pack"
```

应返回 `HTTP/1.1 200 OK`。`content-type` 应为 `text/plain` 或 `application/octet-stream`
(dumb HTTP)。**绝对不应该是** `application/x-git-upload-pack-advertisement` —
若看到这个 = Caddyfile 还残留旧 content-type 覆盖,改 Caddyfile 删那三行 `header @gitrefs/@packfiles/@idxfiles Content-Type ...`,reload。

**链路 2: marketplace.json 内嵌可读**

```powershell
$tmp = "$env:TEMP\mp-test"
if (Test-Path $tmp) { Remove-Item -Recurse -Force $tmp }
git clone https://files.uuhfn.cloud/git/bifrost-internal-plugins.git $tmp
Get-Content "$tmp\.claude-plugin\marketplace.json" -Encoding UTF8 | Select-String '"name"' | Select-Object -First 5
Remove-Item -Recurse -Force $tmp
```

期望: 5 行 name 字段, 含 `"name": "team-uuhfn"` 和 plugin name。

**链路 3: git-subdir 目标 sparse-checkout 可达**

⚠️ **dumb HTTP 不支持 `--depth` / `--filter=blob:none`** ("dumb http transport does not
support shallow capabilities")。退化为全量 clone + 本地 sparse-checkout 验证:

```powershell
$tmp2 = "$env:TEMP\subdir-test"
if (Test-Path $tmp2) { Remove-Item -Recurse -Force $tmp2 }
git clone https://files.uuhfn.cloud/git/claude-for-legal-ZH.git $tmp2
cd $tmp2
git sparse-checkout init
git sparse-checkout set commercial-legal
dir commercial-legal
cd C:\caddy
Remove-Item -Recurse -Force $tmp2
```

期望: `commercial-legal\` 下有 `.claude-plugin\plugin.json`、`agents` 或 `skills` 等。

> 注: Claude Code 客户端的 `git-subdir` source **可能也走 shallow/partial clone**,
> 如步骤 E 报相同 shallow capabilities 错 → 必须切 smart HTTP (见 §smart-http-upgrade)。
> 当前 dumb HTTP 仅在客户端不强制 shallow 时可用。

---

### 步骤 E. 在团队成员机器上端到端验证

挑一台干净 Windows / macOS 机器(**或自己的笔记本,不在 VPS 上**),跑:

```
# Claude Code 内:
/plugin marketplace add https://files.uuhfn.cloud/git/bifrost-internal-plugins.git
```

应输出:

```
✓ Added marketplace 'team-uuhfn' (12 plugins)
```

然后:

```
/plugin install commercial-legal@team-uuhfn
```

**两种结果**:

| 结果 | 含义 | 后续动作 |
|---|---|---|
| `✓ Installed commercial-legal@team-uuhfn` | Claude Code git-subdir 客户端不强制 shallow,dumb HTTP 够用 | 全通,走步骤 F |
| `fatal: ... shallow capabilities` 或类似 | Claude Code 强制 partial/shallow clone | 切 smart HTTP — 见 §smart-http-upgrade |

打开新会话,`/help` 能看到 commercial-legal 提供的 slash 命令 → 端到端通。

---

### §smart-http-upgrade — 客户端要 shallow 时的升级路径

如果步骤 E install 失败 (shallow capabilities 报错), 三选一:

**方案 1 (推荐): Caddy + git-http-backend.exe (CGI 模式)**

Git for Windows 自带 `git-http-backend.exe` 在 `C:\Program Files\Git\mingw64\libexec\git-core\`。
Caddy 无原生 CGI 但社区有 `caddy-cgi` 插件。需重新编译 caddy.exe 含 cgi module:

```powershell
# 用 xcaddy 构建
go install github.com/caddyserver/xcaddy/cmd/xcaddy@latest
xcaddy build --with github.com/aksdb/caddy-cgi/v2
# 替换 C:\caddy\caddy.exe
```

Caddyfile `/git/*` handler 改 (替换原 dumb HTTP `file_server`):

```caddy
handle_path /git/* {
    cgi * "C:/Program Files/Git/mingw64/libexec/git-core/git-http-backend.exe" {
        env GIT_PROJECT_ROOT C:/caddy/git
        env GIT_HTTP_EXPORT_ALL 1
        pass_env PATH
    }
}
```

**方案 2: Gitea 容器**

VPS 装 Docker Desktop 或直接跑 gitea binary,起 :3000,Caddy 反代:

```caddy
handle_path /git/* {
    reverse_proxy 127.0.0.1:3000 {
        header_up Host {host}
        header_up X-Forwarded-Proto https
    }
}
```

Gitea 内部跑 smart HTTP,支持 shallow / partial clone / sparse。

**方案 3: 改 marketplace.json source 类型**

把 `git-subdir` 全部换成 `url` (整仓 clone) — 牺牲带宽 (每 plugin 拉 17MB 整仓),
但绝对兼容 dumb HTTP:

```json
{
  "name": "commercial-legal",
  "source": {
    "source": "url",
    "url": "https://files.uuhfn.cloud/git/claude-for-legal-ZH.git"
  }
}
```

⚠️ 此方案下 Claude Code 客户端拿到整仓后,要靠 `plugin.json` 的 `commands`/`agents`/
`skills` path 字段定位单 plugin 的 sub-tree — 实测需进一步验证 Claude Code 是否支持此用法。
**优先试方案 1 或 2**。

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
| Caddy `/git/*` handler 没 401/IP 白名单 = 公网任何人可访问 marketplace catalog | 如内部插件含敏感信息,加 Caddy basicauth/IP allowlist; 当前 claude-for-legal-ZH 是公开 Apache-2.0 不敏感 |
| force-push 覆盖团队成员本地缓存 | Claude Code `marketplace update` 会自动 reset to remote; 如团队报"安装版本回退"是正常行为 |
| **dumb HTTP 不支持 shallow / partial clone** | 客户端不强制时 OK; 强制 shallow 时需切 smart HTTP (见 §smart-http-upgrade) |
| **Caddy 设错 `Content-Type: application/x-git-upload-pack-advertisement`** | 让 client 走 smart HTTP 但 server 是 dumb HTTP → "remote end hung up"。Caddyfile 别加这个 header,让默认 mime guess |
| **bare repo init 后 HEAD 默认 master,push main 后 HEAD 悬空** | setup 脚本 step 7 已 `symbolic-ref HEAD refs/heads/main`; 历史部署需手动跑一次 |
| Win PowerShell 5.1 默认 ANSI 读 UTF-8 .ps1 → 中文字面量乱码引发 parser error | 脚本 Write-Host 全 ASCII 化; 或装 PowerShell 7 用 `pwsh` 跑 |
| upstream mirror sync 失败导致 stale catalog | 团队 install 拿到的是 mirror 当前 HEAD; 定时任务失败时手动跑 `Start-ScheduledTask -TaskName claude-for-legal-sync` |

---

**部署完成确认清单**:

- [ ] 步骤 A: `git ls-remote https://files.uuhfn.cloud/git/claude-for-legal-ZH.git` 返回 SHA
- [ ] 步骤 B: marketplace 源目录在 `C:\caddy\scripts\team-uuhfn-marketplace\`
- [ ] 步骤 C: `setup-marketplace-vps.ps1` 末尾输出 SETUP COMPLETE
- [ ] 步骤 D 链路 0: `Get-Content C:\caddy\git\bifrost-internal-plugins.git\HEAD` = `ref: refs/heads/main`
- [ ] 步骤 D 链路 1: `curl -I .../info/refs?service=git-upload-pack` 返 200,content-type **不是** smart HTTP advertisement
- [ ] 步骤 D 链路 2: `git clone` marketplace 仓库 + `marketplace.json` 有 12 plugin
- [ ] 步骤 D 链路 3: `git clone` claude-for-legal-ZH 仓库 + sparse-checkout commercial-legal 子目录可见
- [ ] 步骤 E 团队成员机器端到端 install 成功(若失败 → 走 §smart-http-upgrade)
- [ ] 步骤 F 团队教程已上传到 `https://files.uuhfn.cloud/docs/`
- [ ] 团队公告群已发

✅ 全部打钩 → 完工。
