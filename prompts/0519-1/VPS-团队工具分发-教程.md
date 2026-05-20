# 团队 AI 工具 VPS 分发教程

> 目标：让团队成员从你的 Windows VPS 一键下载并配置好三个工具：
> - **claude-code**（npm 包）— AI 编码 CLI
> - **cc-switch**（GitHub 桌面应用）— 多供应商切换器
> - **trellis**（npm 包，需 Python）— AI 编码任务/规范管理框架
>
> 全程无需翻墙。
> 适合人群：第一次搭这种东西的人，按顺序抄命令即可。
> 预计耗时：1 ~ 1.5 小时（含等待下载）。

---

## 0. 先看懂一张图

```
                          ┌────────────────────────────────────────┐
                          │  Windows VPS (国内可达, 你在管)         │
                          │                                        │
                          │   ┌────────────────────────────┐       │
                          │   │ Caddy (前台, 端口 443)      │       │
   团队成员              │   │   ├─ npm.uuhfn.cloud        │       │
   (浏览器/CMD/PowerShell)│   │   │   ↓ 反代               │       │
        │                 │   │   │   Verdaccio :4873     │ ← npm 私服
        │  HTTPS          │   │   │     - claude-code      │
        │  请求            │   │   │     - @mindfoldhq/trellis │
        ├─────────────────┼──→│   └─ files.uuhfn.cloud     │       │
        │                 │   │       ↓ 静态服务            │       │
        │                 │   │       C:\caddy\dist\       │ ← 文件下载
        │                 │   │         ├─ cc-switch.msi   │       │
        │                 │   │         ├─ node.msi        │       │
        │                 │   │         ├─ python.exe      │       │
        │                 │   │         └─ setup.bat        │       │
        │                 │   └────────────────────────────┘       │
        ↓                 └────────────────────────────────────────┘
   终端机器
   (装 Node + Python + claude-code + cc-switch + trellis)
```

**关键概念三句话**：
1. **npm 私服 (Verdaccio)**：团队装 npm 包时不走 npmjs.com，而走你的 VPS。VPS 第一次帮他们去 npmjs.com 拉一份缓存下来，之后所有人都从 VPS 拉，国内速度飞快。
2. **静态文件分发**：cc-switch 是 `.msi` 安装包不是 npm 包，单独走 HTTP 文件下载即可。Python 安装器同理。
3. **Caddy 反代**：一个统一的入口，按域名分流到 Verdaccio 或静态文件目录，自动处理 HTTPS。

**三个工具对照表**：

| 工具 | 是什么 | 装在哪 | 怎么装 | 前置依赖 |
|---|---|---|---|---|
| claude-code | AI 编码 CLI | npm 全局 | `npm i -g @anthropic-ai/claude-code` | Node 18+ |
| cc-switch | 桌面 GUI | 系统程序 | 双击 .msi | 无 |
| trellis | 任务/规范管理 CLI | npm 全局 | `npm i -g @mindfoldhq/trellis` | **Node 18+ AND Python 3.9+** |

---

## 1. 准备清单（开干前对照检查）

| 项 | 你需要有 | 怎么获得 |
|---|---|---|
| Windows VPS | 一台可以远程桌面连上的 Windows Server | 已有 ✅ |
| 域名 | `uuhfn.cloud`（已用于 api.uuhfn.cloud） | 已有 ✅ |
| Cloudflare 账号 | 管理 DNS + Origin 证书 | 已有 ✅ |
| Caddyfile | 已经在 VPS 上 `C:\caddy\Caddyfile` | 已有 ✅ |
| Cloudflare Origin 证书 | `C:/caddy/certs/uuhfn-cloud-origin.pem` 含 `*.uuhfn.cloud` SAN | **需要检查** ⚠️ |
| Node.js | 暂无 | 本教程第 2 步装 |
| Python 3.9+ | VPS 自身**不一定要**（Verdaccio 不需要 Python）；但要给**团队**分发 Python 安装包 | 本教程第 7 步缓存 |
| Verdaccio | 暂无 | 本教程第 3 步装 |

---

## 2. 第一步：在 VPS 上装 Node.js

> 为什么先装 Node：Verdaccio 是用 Node.js 写的 npm 包，必须先有 Node 才能装它。

### 2.1 远程桌面登录 VPS，用管理员身份打开 **PowerShell**

> 桌面左下角搜索 "powershell" → 右键 "Windows PowerShell" → "以管理员身份运行"

### 2.2 复制粘贴下面三行，回车执行

```powershell
$url = "https://nodejs.org/dist/v20.18.1/node-v20.18.1-x64.msi"
Invoke-WebRequest -Uri $url -OutFile "$env:TEMP\node.msi"
msiexec /i "$env:TEMP\node.msi" /qn /norestart
```

**做了什么**：下载 Node.js 20.18.1 LTS 安装包到临时目录，然后静默安装（不弹窗）。

### 2.3 等 30 秒，**关闭 PowerShell 重新打开**（让环境变量 PATH 生效）

### 2.4 验证

```powershell
node -v
npm -v
```

**应输出**：
```
v20.18.1
10.8.2
```

如果提示 `'node' 不是内部或外部命令`，说明 PATH 没生效 → 重启 VPS 一次再试。

---

## 3. 第二步：装 Verdaccio + pm2（npm 私服 + 守护进程）

### 3.1 在管理员 PowerShell 里执行：

> **先放开脚本执行权限**（Windows 默认禁，否则 `pm2-startup` 会报 "running scripts is disabled"）：
>
> ```powershell
> Set-ExecutionPolicy RemoteSigned -Scope CurrentUser -Force
> ```
>
> 然后再装包：

```powershell
npm i -g pnpm
npm i -g pm2 pm2-windows-startup
pm2-startup install
npm i -g verdaccio
```

**遇到 `running scripts is disabled on this system` 错误**：
说明上面的 `Set-ExecutionPolicy` 没执行或没生效。重新执行那行命令，然后**关闭 PowerShell 重新打开**再跑 `pm2-startup install`。

**做了什么**：
- `pnpm`：更快的 npm 替代品（可选但推荐）
- `pm2 + pm2-windows-startup`：让服务能开机自启、崩了自动重启
- `verdaccio`：npm 私服本体

### 3.2 首次启动 Verdaccio 生成默认配置

```powershell
verdaccio
```

看到类似输出：
```
info --- config file  - C:\Users\你\AppData\Roaming\verdaccio\config.yaml
info --- http address - http://localhost:4873/
```

**记下配置文件路径**（一般是 `C:\Users\Administrator\AppData\Roaming\verdaccio\config.yaml`），然后按 `Ctrl+C` 退出。

### 3.3 编辑 Verdaccio 配置

用记事本打开 `config.yaml`，**整个文件替换为**：

```yaml
storage: ./storage
plugins: ./plugins

listen: 0.0.0.0:4873

uplinks:
  npmjs:
    url: https://registry.npmjs.org/
    timeout: 60s
    max_fails: 10
    fail_timeout: 5m
    cache: true

packages:
  '@*/*':
    access: $all
    publish: $authenticated
    proxy: npmjs
  '**':
    access: $all
    publish: $authenticated
    proxy: npmjs

max_body_size: 200mb

web:
  enable: true
  title: 团队 NPM 镜像

log:
  type: file
  path: C:/caddy/logs/verdaccio.log
  format: pretty-timestamped
  level: info
```

> **配置含义**：
> - `listen: 0.0.0.0:4873`：监听所有网卡的 4873 端口（必须，否则 Caddy 反代不到）
> - `uplinks.npmjs`：当本地没有某个包时，去 npmjs.org 拉
> - `proxy: npmjs`：所有包都走 npmjs 上游 + 本地缓存
> - `access: $all`：所有人都能下载（不需要登录）
> - `publish: $authenticated`：发布需要登录（团队只下载，不会用到）

### 3.4 创建日志目录

```powershell
mkdir C:\caddy\logs -Force
```

### 3.5 用 pm2 启动 Verdaccio

> ⚠️ **Windows 重要坑**：直接 `pm2 start verdaccio` 会让 PM2 把 `verdaccio.cmd`（批处理 shim）当 Node.js JS 文件加载，报 `SyntaxError: Invalid or unexpected token` at `@ECHO off`。必须喂 **真实 JS 入口**。

```powershell
# 1. 找到真实 JS 入口
$verdaccioJs = "$env:APPDATA\npm\node_modules\verdaccio\bin\verdaccio"
Test-Path $verdaccioJs
```

应输出 `True`。若 `False`，跑：
```powershell
npm root -g
```
用输出路径拼出 `<那个路径>\verdaccio\bin\verdaccio`，重设 `$verdaccioJs`。

```powershell
# 2. 启动（关键：--interpreter node）
pm2 start $verdaccioJs --name verdaccio --interpreter node
pm2 save
```

**应输出**：
```
[PM2] Starting <verdaccio JS 路径> in fork_mode (1 instance)
[PM2] Done.
```

```powershell
# 3. 立即看日志确认成功启动
pm2 logs verdaccio --lines 20 --nostream
```

**应看到**：
```
info --- config file - C:\Users\Administrator\AppData\Roaming\verdaccio\config.yaml
info --- http address - http://0.0.0.0:4873/
```

**如果 status 显示 stopped 或 errored**：
```powershell
pm2 logs verdaccio --lines 50 --nostream
```
看到 `VERDACCIO.CMD` 报错 → 重新执行第 2 步前的所有命令（确保 `--interpreter node` 加了）。

### 3.6 验证 Verdaccio 跑起来了

```powershell
curl http://127.0.0.1:4873
```

**应输出一大段 HTML**（Verdaccio 的 Web 界面）。

---

## 4. 第三步：检查并修正 Cloudflare 证书

### 4.1 检查现有证书是否覆盖通配符域名

**方法 A：用 Windows 自带 certutil（推荐）**

```powershell
certutil -dump "C:\caddy\certs\uuhfn-cloud-origin.pem" | Select-String -Pattern "DNS Name|Subject:"
```

**期望看到的内容**：
```
Subject: CN=Cloudflare Origin Certificate
DNS Name=*.uuhfn.cloud
DNS Name=uuhfn.cloud
```

**方法 B：如果 VPS 装了 Git for Windows（带 openssl）**

```powershell
& "C:\Program Files\Git\usr\bin\openssl.exe" x509 -in "C:\caddy\certs\uuhfn-cloud-origin.pem" -text -noout | Select-String "DNS:"
```

> ⚠️ **PowerShell 5.1 上不要用** `[X509Certificate2]::CreateFromPemFile()`，那是 .NET 5+ 才有的方法，Windows Server 默认 PS 5.1 会报 "does not contain a method"。

### 4.2 如果只看到 `api.uuhfn.cloud`，重新签发证书

1. 登录 [Cloudflare Dashboard](https://dash.cloudflare.com/)
2. 选中 `uuhfn.cloud` 域名
3. 左侧菜单 → **SSL/TLS** → **Origin Server** → **Create Certificate**
4. **Hostnames** 填写：
   ```
   *.uuhfn.cloud
   uuhfn.cloud
   ```
5. **Validity**: 15 years（默认）
6. **Create** → 复制证书内容和私钥内容
7. VPS 上：
   - 用记事本打开 `C:/caddy/certs/uuhfn-cloud-origin.pem` → 替换为新证书内容
   - 用记事本打开 `C:/caddy/certs/uuhfn-cloud-origin-key.pem` → 替换为新私钥内容
8. 保存退出

---

## 5. 第四步：在 Cloudflare 加 DNS 记录

1. Cloudflare Dashboard → `uuhfn.cloud` → **DNS** → **Records**
2. **Add record**，加两条：

| Type | Name | Content | Proxy status |
|---|---|---|---|
| A | `npm` | 你的 VPS 公网 IP | 🟧 Proxied |
| A | `files` | 你的 VPS 公网 IP | 🟧 Proxied |

3. **SSL/TLS** → **Overview** → 模式确认是 **Full (strict)**

---

## 6. 第五步：重载 Caddy

> Caddyfile 在之前对话里已经更新好了，包含 `npm.uuhfn.cloud` 和 `files.uuhfn.cloud` 两个块。

### 6.1 创建静态文件目录

```powershell
mkdir C:\caddy\dist -Force
```

### 6.2 重载 Caddy 配置

```powershell
cd C:\caddy
caddy reload --config Caddyfile
```

**应输出**：
```
{"level":"info","msg":"using provided configuration"}
```

如果 Caddy 不是用 pm2 跑的，先看一下：
```powershell
pm2 list
```
如果列表里没有 caddy，先启动：
```powershell
pm2 start "C:\caddy\caddy.exe" --name caddy -- run --config C:\caddy\Caddyfile
pm2 save
```

---

## 7. 第六步：把要分发的文件放进 dist 目录

### 7.1 缓存 cc-switch 最新版

> 查看最新版本号：访问 https://github.com/farion1231/cc-switch/releases

```powershell
$ver = "v3.14.1"   # 用最新版替换这里
cd C:\caddy\dist

Invoke-WebRequest "https://github.com/farion1231/cc-switch/releases/download/$ver/CC-Switch-$ver-Windows.msi" -OutFile "CC-Switch-$ver-Windows.msi"
Invoke-WebRequest "https://github.com/farion1231/cc-switch/releases/download/$ver/CC-Switch-$ver-Windows-Portable.zip" -OutFile "CC-Switch-$ver-Windows-Portable.zip"
```

> 如果 VPS 国内访问 GitHub 慢，挂代理或者从你自己电脑下载好上传到 VPS。

### 7.2 缓存 Node.js MSI（给团队 bootstrap）

```powershell
Invoke-WebRequest "https://nodejs.org/dist/v20.18.1/node-v20.18.1-x64.msi" -OutFile "node-v20.18.1-x64.msi"
```

### 7.2b 缓存 Python 安装包（给 Trellis 用）

> Trellis 的 hook 和 task.py 脚本依赖 Python 3.9+。Windows 上推荐 Python 3.12（最新稳定）。

```powershell
Invoke-WebRequest "https://www.python.org/ftp/python/3.12.7/python-3.12.7-amd64.exe" -OutFile "python-3.12.7-amd64.exe"
```

### 7.2c 缓存 cc-switch 多平台安装包

> Windows 用 .msi，macOS 用 .dmg（arm64/x64 各一个），Linux 用 .AppImage。
> 先查 release 真实文件名：
>
> ```powershell
> $rel = Invoke-RestMethod "https://api.github.com/repos/farion1231/cc-switch/releases/latest"
> $rel.assets | Select-Object name, browser_download_url | Format-Table -AutoSize
> ```
>
> 然后按真实文件名下载（示例 v3.14.1）：

```powershell
$ver = "v3.14.1"
$base = "https://github.com/farion1231/cc-switch/releases/download/$ver"
$assets = @(
    "CC-Switch-$ver-Windows.msi",
    "CC-Switch-$ver-Windows-Portable.zip",
    "CC-Switch-$ver-macOS-arm64.dmg",
    "CC-Switch-$ver-macOS-x64.dmg",
    "CC-Switch-$ver-Linux.AppImage",
    "CC-Switch-$ver-Linux.deb"
)
foreach ($a in $assets) {
    Invoke-WebRequest "$base/$a" -OutFile $a
}
```

> 实际 release 可能没全部架构包，按 7.2c 查到的为准。

### 7.3 创建团队成员用的一键安装脚本（跨平台）

教程仓库已经提供两个脚本，把它们都放到 `C:\caddy\dist\`：

- **`setup.bat`** — Windows 团队成员双击即可
- **`setup.sh`** — macOS / Linux 团队成员 `curl | bash` 或下载后 `bash setup.sh`

两个脚本完整内容见与本文档同目录的 `setup.bat` 和 `setup.sh`。**部署时直接把这两个文件拷到 VPS 的 `C:\caddy\dist\` 目录即可**。

### 7.3a Windows setup.bat 工作流

1. 检测 Node.js / Python 是否安装（缺则从 VPS 静态目录下载 MSI/EXE 装上）
2. 配置 npm registry → VPS Verdaccio
3. 走 VPS npm 私服装 `@anthropic-ai/claude-code`
4. 走 VPS npm 私服装 `@mindfoldhq/trellis`
5. 从 VPS 静态目录下载 cc-switch MSI 静默安装

### 7.3b macOS / Linux setup.sh 工作流

**macOS**：
1. 自动安装 Homebrew（如缺）并切换到 USTC 镜像加速
2. `brew install node@20 python@3.12`
3. 配 npm registry → VPS
4. npm i -g claude-code + trellis（走 VPS）
5. 从 VPS 下载 `CC-Switch-vX.Y.Z-macOS-arm64.dmg`（或 x64）→ 挂载 → 拷贝到 `/Applications/` → 解 quarantine

**Linux**：
1. 检测包管理器（apt/dnf/yum/pacman）
2. 装 Node 20（NodeSource 源）+ Python3
3. 配 npm registry → VPS
4. npm i -g claude-code + trellis
5. 从 VPS 下载 `CC-Switch-vX.Y.Z-Linux.AppImage` 到 `~/.local/bin/`

### 7.4 检查目录文件齐全

```powershell
dir C:\caddy\dist
```

**应看到**（macOS/Linux 包按 7.2c 查到的真实文件名）：
```
CC-Switch-v3.14.1-Windows.msi
CC-Switch-v3.14.1-Windows-Portable.zip
CC-Switch-v3.14.1-macOS-arm64.dmg
CC-Switch-v3.14.1-macOS-x64.dmg
CC-Switch-v3.14.1-Linux.AppImage
node-v20.18.1-x64.msi
python-3.12.7-amd64.exe
setup.bat
setup.sh
test.txt
```

---

## 8. 第七步：防火墙放行（如果 VPS 启用了 Windows 防火墙）

```powershell
New-NetFirewallRule -DisplayName "Caddy HTTPS" -Direction Inbound -Protocol TCP -LocalPort 443 -Action Allow
New-NetFirewallRule -DisplayName "Caddy HTTP" -Direction Inbound -Protocol TCP -LocalPort 80 -Action Allow
```

> Verdaccio 端口 4873 **不要**开放公网，只让 Caddy 内部访问。

---

## 9. 验证整套服务正常

### 9.1 在 VPS 上自测

```powershell
curl https://npm.uuhfn.cloud/
curl https://files.uuhfn.cloud/
```

两条都应该返回 HTML 内容（一个是 Verdaccio 主页，一个是文件列表）。

### 9.2 在你自己电脑上（非 VPS）测试

打开浏览器访问：
- https://npm.uuhfn.cloud/ → 看到 Verdaccio 界面
- https://files.uuhfn.cloud/ → 看到文件列表，能下载 setup.bat

---

## 10. 团队成员使用方法

> 把下面这段发给团队成员即可。

### 10.1 方式一：一键脚本（推荐）

**Windows 团队成员**：
1. 浏览器打开 https://files.uuhfn.cloud/setup.bat 下载脚本
2. **右键** → **以管理员身份运行**
3. 按提示等待完成（首次需重启命令行一次）
4. 测试：
   ```cmd
   claude --version
   trellis --version
   ```
5. 开始菜单 / 桌面会出现 **CC Switch** 图标，双击启动

**macOS / Linux 团队成员**：
```bash
curl -fsSL https://files.uuhfn.cloud/setup.sh | bash
```

或下载后再跑（便于审查内容）：
```bash
curl -fsSL https://files.uuhfn.cloud/setup.sh -o setup.sh
less setup.sh   # 检查脚本内容
bash setup.sh
```

完成后：
```bash
claude --version
trellis --version
# macOS: open -a "CC Switch"
# Linux: ~/.local/bin/cc-switch.AppImage &
```

### 10.2 方式二：手动安装

```cmd
:: 1. 装 Node.js（如已有跳过）
:: 下载 https://files.uuhfn.cloud/node-v20.18.1-x64.msi 双击安装

:: 2. 装 Python（如已有跳过，必须勾选 "Add Python to PATH"）
:: 下载 https://files.uuhfn.cloud/python-3.12.7-amd64.exe 双击安装

:: 3. 配 npm 私服
npm config set registry https://npm.uuhfn.cloud/

:: 4. 装 claude-code
npm i -g @anthropic-ai/claude-code

:: 5. 装 trellis
npm i -g @mindfoldhq/trellis

:: 6. 装 cc-switch
:: 下载 https://files.uuhfn.cloud/CC-Switch-v3.14.1-Windows.msi 双击安装
```

### 10.3 在自己项目里初始化 Trellis

```cmd
:: 进入你的项目根目录
cd D:\my-project

:: 初始化 Trellis（自动检测 Claude Code）
trellis init -u 你的名字

:: 如果同时用 Cursor / OpenCode / Codex，加对应 flag：
:: trellis init --cursor --codex -u 你的名字
```

完成后项目里会出现 `.trellis/` 目录，团队成员就能用任务管理、规范注入等功能。

---

## 11. 日常维护（你需要做的）

### 11.1 cc-switch 出新版了怎么办？

```powershell
$NEW_VER = "v3.15.0"   # 改成新版号
cd C:\caddy\dist

Invoke-WebRequest "https://github.com/farion1231/cc-switch/releases/download/$NEW_VER/CC-Switch-$NEW_VER-Windows.msi" -OutFile "CC-Switch-$NEW_VER-Windows.msi"

# 改 setup.bat 里的 CC_SWITCH_VER 变量为新版号
# 通知团队重跑 setup.bat
```

### 11.2 claude-code / trellis 出新版了怎么办？

**什么都不用做**。Verdaccio 自动从 npmjs.org 拉新版。
团队成员执行：
```cmd
npm update -g @anthropic-ai/claude-code
npm update -g @mindfoldhq/trellis
```
即可。

### 11.3 看日志

```powershell
:: Verdaccio
Get-Content C:\caddy\logs\verdaccio.log -Tail 50

:: Caddy (NewAPI / npm / files 三个域名)
Get-Content C:\caddy\logs\newapi-access.log -Tail 20
Get-Content C:\caddy\logs\verdaccio-access.log -Tail 20
Get-Content C:\caddy\logs\files-access.log -Tail 20
```

### 11.4 服务管理

```powershell
:: 列出所有 pm2 守护的服务
pm2 list

:: 重启某个服务
pm2 restart verdaccio
pm2 restart caddy

:: 看实时日志
pm2 logs verdaccio
```

---

## 12. 常见故障排查

### Q1: 团队成员执行 `npm i` 超时

**检查**：
1. 浏览器能不能打开 https://npm.uuhfn.cloud/
2. 团队 registry 配对了吗？
   ```cmd
   npm config get registry
   ```
   应该输出 `https://npm.uuhfn.cloud/`

### Q2: cc-switch 安装时报 "无法验证发布者"

**原因**：Windows SmartScreen 拦截。
**解决**：右键 .msi → 属性 → 勾选 "解除锁定" → 确定。

### Q3: 浏览器访问 `https://npm.uuhfn.cloud/` 提示证书错误

**原因**：Cloudflare Origin 证书没覆盖 `*.uuhfn.cloud`。
**解决**：回到第 4.2 步重新签发证书。

### Q4: `caddy reload` 报错 `adapting config using caddyfile: ...`

**原因**：Caddyfile 语法错误。
**解决**：
```powershell
caddy validate --config C:\caddy\Caddyfile
```
会告诉你哪一行错了。

### Q5: 团队成员执行 `trellis init` 报 "Python not found"

**原因**：Python 没装或没加 PATH。
**解决**：
1. 确认 `python --version` 能输出版本号
2. 若没装：从 https://files.uuhfn.cloud/python-3.12.7-amd64.exe 重新下载，安装时**勾选 "Add Python to PATH"**
3. 装完关闭所有 CMD 窗口重开

### Q6: `trellis init` 卡住或拉取 spec 模板失败

**原因**：Trellis 默认从 GitHub 拉模板，国内可能慢。
**解决**：让团队挂代理临时跑一次 `trellis init` 即可（init 只跑一次，之后用 trellis 命令不依赖 GitHub）。

### Q7: VPS 重启后服务没自启

**检查**：
```powershell
pm2 list
```
如果列表空 → 执行：
```powershell
pm2 resurrect
```

如果还不行，重新配自启：
```powershell
pm2 save
pm2-startup install
```

---

## 13. 完成检查清单

跑完整个教程后，对照打钩：

- [ ] VPS 上 `node -v` 输出 v20.x
- [ ] VPS 上 `pm2 list` 看到 verdaccio + caddy 两个 online
- [ ] Cloudflare DNS 有 `npm.uuhfn.cloud` 和 `files.uuhfn.cloud` 两条 A 记录
- [ ] Origin 证书覆盖 `*.uuhfn.cloud`
- [ ] 自己电脑浏览器能打开 https://npm.uuhfn.cloud/ 和 https://files.uuhfn.cloud/
- [ ] `C:\caddy\dist\` 里有 cc-switch.msi、node.msi、**python.exe**、setup.bat
- [ ] 找一台干净的 Windows 电脑试过 setup.bat 一键安装成功
- [ ] 测试机上 `claude --version`、`trellis --version` 都能输出版本号
- [ ] 测试机上 `trellis init -u test` 能成功生成 `.trellis/` 目录

全部打钩 → 通知团队，培训可以开始 🎉

---

## 附录 A：所有命令的"做了什么"一句话总结

| 命令 | 做了什么 |
|---|---|
| `node -v` | 验证 Node.js 装好了 |
| `npm i -g xxx` | 全局安装 xxx 工具（命令行随处可用） |
| `pm2 start xxx` | 让 xxx 在后台跑，崩了自动重启 |
| `pm2 save` | 记住当前所有 pm2 任务，下次开机自动恢复 |
| `caddy reload` | 不中断服务地重新加载 Caddyfile |
| `caddy validate` | 检查 Caddyfile 语法对不对 |
| `Invoke-WebRequest` | PowerShell 的下载命令（相当于 wget/curl） |
| `msiexec /i xxx.msi /qn` | 静默安装 MSI 包，不弹窗 |
| `npm config set registry xxx` | 改 npm 默认源，之后 npm 都走这个 URL |
| `trellis init -u 名字` | 在当前目录初始化 Trellis，生成 `.trellis/` 和 `.claude/` |
| `trellis --version` | 验证 Trellis 装好 |
| `python --version` | 验证 Python 装好 |

## 附录 B：所有要记住的 URL

| URL | 用途 |
|---|---|
| https://npm.uuhfn.cloud/ | 团队 npm 私服 |
| https://files.uuhfn.cloud/ | 团队文件分发 |
| https://files.uuhfn.cloud/setup.bat | 团队一键安装脚本 |
| https://github.com/farion1231/cc-switch/releases | cc-switch 新版本检查 |
| https://github.com/mindfold-ai/Trellis | Trellis 官方仓库 |
| https://docs.trytrellis.app | Trellis 官方文档 |
| https://nodejs.org/dist/ | Node.js 历史版本下载 |
| https://www.python.org/ftp/python/ | Python 历史版本下载 |

---

**写完日期**：2026-05-19
**适用版本**：cc-switch v3.14.x / Node.js 20 LTS / Python 3.12 / Trellis 0.5+ / Verdaccio 5.x / Caddy 2.x
