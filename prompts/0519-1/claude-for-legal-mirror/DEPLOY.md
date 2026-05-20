# VPS 部署清单 — claude-for-legal-ZH 镜像

> 这一份是给 **VPS 管理员**（ZRainbow 你自己）看的。团队成员只需要看 `团队-安装claude-for-legal-ZH-教程.md`。

---

## 一、本目录文件清单

| 文件 | 作用 | 部署位置 |
|---|---|---|
| `setup-mirror.ps1` | 一次性初始化：clone bare repo、首次打包 tarball | 临时执行，无需常驻 |
| `sync-claude-for-legal.ps1` | 每日同步脚本 | 复制到 `C:\caddy\scripts\` |
| `register-task.ps1` | 注册 Windows 计划任务 | 临时执行 |
| `Caddyfile-additions.txt` | Caddyfile 增量配置 | 合并到 `C:\caddy\Caddyfile` |
| `团队-安装claude-for-legal-ZH-教程.md` | 团队侧使用文档 | 上传到 `C:\caddy\dist\docs\` 供下载 |

---

## 二、部署步骤（按顺序）

### 1. 上传脚本到 VPS

把 `setup-mirror.ps1`、`sync-claude-for-legal.ps1`、`register-task.ps1` 复制到 VPS 的 `C:\caddy\scripts\`（不存在就创建）。

### 2. 检查并安装 git

在 VPS 上执行：

```powershell
git --version
```

如果没装，下载安装：[Git for Windows](https://git-scm.com/download/win)。装好后**重新打开 PowerShell**。

### 3. 跑初始化脚本

以**管理员身份**打开 PowerShell：

```powershell
cd C:\caddy\scripts
.\setup-mirror.ps1
```

预期输出末尾应该看到 `=== SETUP COMPLETE ===` 和 4 行路径。

### 4. 合并 Caddyfile

打开 `Caddyfile-additions.txt`，把 `files.uuhfn.cloud { ... }` 整块**替换**掉现有 Caddyfile 中的同名块。然后热重载：

```powershell
curl.exe -X POST "http://127.0.0.1:2019/load" `
         -H "Content-Type: text/caddyfile" `
         --data-binary "@C:\caddy\Caddyfile"
```

应该返回空响应（HTTP 200）。如果报错，检查 Caddyfile 语法。

### 5. 验证两条链路

```powershell
# tarball 链路
curl.exe -I https://files.uuhfn.cloud/claude-for-legal-ZH/releases/latest.tar.gz

# git dumb HTTP 链路
git ls-remote https://files.uuhfn.cloud/git/claude-for-legal-ZH.git
```

第一条应返回 `HTTP/2 200` + `content-type: application/gzip`。
第二条应返回一行 commit SHA + `refs/heads/main`。

### 6. 注册每日同步任务

```powershell
.\register-task.ps1
```

预期看到 `task 'claude-for-legal-sync' installed.`。立即触发一次验证：

```powershell
Start-ScheduledTask -TaskName claude-for-legal-sync
# 等几秒
Get-Content "C:\caddy\logs\sync-claude-for-legal\$(Get-Date -Format 'yyyy-MM').log" -Tail 10
```

应该看到 `no upstream change` 或 `sync done in Ns`。

### 7. 上传教程文档

```powershell
# 假设上传后放在
mkdir C:\caddy\dist\docs -Force
Copy-Item "C:\caddy\scripts\团队-安装claude-for-legal-ZH-教程.md" `
          C:\caddy\dist\docs\
```

团队成员就可以访问：`https://files.uuhfn.cloud/docs/`。

---

## 三、运维操作速查

| 想做什么 | 命令 |
|---|---|
| 立刻同步一次（不等 02:00） | `Start-ScheduledTask -TaskName claude-for-legal-sync` |
| 查看下一次自动同步时间 | `Get-ScheduledTask -TaskName claude-for-legal-sync \| Get-ScheduledTaskInfo` |
| 查看本月同步日志 | `Get-Content "C:\caddy\logs\sync-claude-for-legal\$(Get-Date -Format 'yyyy-MM').log"` |
| 停用同步 | `Disable-ScheduledTask -TaskName claude-for-legal-sync` |
| 卸载同步任务 | `Unregister-ScheduledTask -TaskName claude-for-legal-sync -Confirm:$false` |
| 手动强制刷新 tarball | 在 `C:\caddy\scripts\` 跑 `.\sync-claude-for-legal.ps1` |
| 切换上游分支 | 编辑 `sync-claude-for-legal.ps1` 的 `$Branch` 变量 |
| 调整 tarball 保留天数 | 编辑同上脚本的 `$RetainDays`（默认 14 天） |
| 清空 git 镜像重头来 | 删除 `C:\caddy\git\claude-for-legal-ZH.git`，重跑 setup-mirror.ps1 |

---

## 四、风险点

1. **VPS 磁盘**：每个 tarball 约几 MB，保留 14 份 → < 100MB。bare git 仓库 < 50MB。可忽略。
2. **上游变更敏感操作**：如果上游强制推送（force-push），bare repo 不会有问题（`git remote update --prune` 会清掉死引用）。但工作树（`tree/`）会通过 `git reset --hard` 强制对齐，所以**不要手动改 `tree/` 下任何文件**。
3. **dumb HTTP 性能**：clone 一次 ~30 秒（取决于上游对象数）。如果未来 repo 膨胀超过 200MB，考虑加 git smart HTTP（需要 git-http-backend.exe + 反向代理改写）。当前规模不需要。
4. **Caddy reload 失败回滚**：如果 reload 失败，旧配置仍在跑（Caddy 不会半成品上线）。改完 Caddyfile 务必先 `caddy validate --config C:\caddy\Caddyfile` 再 reload。

---

**部署完成验证**：从你电脑（不是 VPS）执行：

```bash
git clone https://files.uuhfn.cloud/git/claude-for-legal-ZH.git /tmp/test-clone
ls /tmp/test-clone
# 应该看到 12 个插件目录 + .claude-plugin/
rm -rf /tmp/test-clone
```

✅ 通过即部署成功。
