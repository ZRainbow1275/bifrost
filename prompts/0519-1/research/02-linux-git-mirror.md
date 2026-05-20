# Research: Linux GitHub 私有镜像 + 定时同步方案对比

- **Query**: 在 Linux 上做 GitHub 仓库私有镜像 + 定时同步的现代方案；对比 Gitea/Forgejo 自动 mirror、systemd timer + git remote update 裸 bare 方案、git smart HTTP (CGI) vs dumb HTTP
- **Scope**: 外部（公网文档/官方手册）
- **Date**: 2026-05-19
- **Source Method**: 直接抓取官方 docs（git-scm.com、docs.gitea.com、forgejo.org、freedesktop.org、nginx.org），辅以 GitHub Releases API 拉取最新版本

---

## 0. 当前基线（Windows VPS 现状）

| 项目 | 当前实现 | 性能特征 |
|---|---|---|
| 镜像方式 | `git clone --mirror` + Windows 计划任务 | 全量 ref + 全量 objects，定时跑 `git remote update` |
| 客户端协议 | dumb HTTP（IIS/简单静态文件服务） | 客户端假定目录布局，多次 HTTP GET 拉松散对象/包 |
| 同步触发 | 计划任务（无随机化、无并发抑制） | Windows Task Scheduler 限于分钟级，无 jitter |
| 维护成本 | 每次新 repo 要手动 init bare + 加任务 | 易遗漏，无 audit |

下面 3 个 Linux 候选方案，全部围绕"降低维护成本 + 提升大仓库拉取性能 + 一键续命"展开。

---

## 1. 话题 1 — Gitea / Forgejo 内置 Pull Mirror

### 1.1 官方机制（来自官方文档原文）

**Gitea Pull Mirror**（[docs.gitea.com/usage/repo-mirror](https://docs.gitea.com/usage/repo-mirror)）：

- 创建路径：**New Migration → 填 GitHub URL → 勾 "This repository will be a mirror"**
- 同步引擎：内置 cron `cron.update_mirrors`（默认 `ENABLED=true`）
- 强制刷新：仓库设置页 → "Synchronize Now" 按钮
- 限制：**只能创建新 repo 时设置 mirror**，不能把已存在 repo 改成 mirror

**Gitea `[mirror]` 默认参数**（[config-cheat-sheet 1.26](https://docs.gitea.com/administration/config-cheat-sheet)）：

```ini
[mirror]
ENABLED = true
DEFAULT_INTERVAL = 8h     ; 默认 8 小时
MIN_INTERVAL = 10m        ; 最小 10 分钟（>1m 硬约束）

[cron.update_mirrors]
ENABLED = true
PULL_LIMIT = 50           ; 每次入队的 pull mirror 数上限
PUSH_LIMIT = 50
```

**Forgejo Pull Mirror**（[forgejo.org/docs/latest/user/repo-mirror](https://forgejo.org/docs/latest/user/repo-mirror/)）：与 Gitea 完全一致的 UI 流程（Forgejo 是 Gitea soft-fork）；同样 `[mirror]` 段，默认 `DEFAULT_INTERVAL=8h`、`MIN_INTERVAL=10m`。Forgejo 额外支持 **SSH 认证** 用于 push mirror（Gitea 不支持，需要 post-receive hook workaround）。

### 1.2 默认端口与最新版本（联网核实）

| 软件 | 最新 Stable | 发布日期 | HTTP_PORT | SSH_PORT | 来源 |
|---|---|---|---|---|---|
| **Gitea** | **v1.26.1** | 2026-04-24 | **3000** | **22**（容器内置 SSH 通常映射到 2222） | [api.github.com/repos/go-gitea/gitea/releases/latest](https://api.github.com/repos/go-gitea/gitea/releases/latest) |
| **Forgejo** | **v15.0.2** | 2026-05-12 | **3000** | **22** | [codeberg.org/api/v1/repos/forgejo/forgejo/releases](https://codeberg.org/api/v1/repos/forgejo/forgejo/releases) |

> 注：`HTTP_PORT=3000`、`SSH_PORT=22` 来自 `[server]` 段官方默认值。生产部署通常反代到 80/443，built-in SSH 改 2222 避开宿主 sshd。

### 1.3 vs 裸 bare repo + cron 的对比

| 维度 | Gitea/Forgejo Pull Mirror | 裸 `git clone --mirror` + cron |
|---|---|---|
| 新增 repo 工作量 | Web UI 三步点击 | 手写 shell：`git clone --mirror`+ `git update-server-info` + cron 行 |
| 多用户访问控制 | 内置（org/team/permission） | 无（需要靠 nginx basic auth / TLS 客户端证书外挂） |
| Web 浏览/搜索 | 完整 Web UI、commit graph、blame | 无（要么再装 cgit / gitweb） |
| LFS 支持 | 原生 | 需要单独跑 `git lfs fetch --all` |
| Token 管理 | 内置加密存储 GitHub PAT | 明文/keyring，每仓库自己管 |
| 同步可观测性 | UI 显示 last-sync、错误回执 | tail cron 日志 |
| 资源占用（空载） | Gitea ~150–250 MB RSS（含 SQLite/PostgreSQL） | <10 MB（纯 git + cron） |
| 升级负担 | 跟随上游季度发版 | 几乎零（git/cron 本身极稳） |

### 1.4 评分

| 指标 | Gitea v1.26 | Forgejo v15 |
|---|---|---|
| **实施复杂度（1=最简单, 5=最难）** | **2** — 单二进制 / Docker compose 一行起 | **2** — 同 Gitea |
| **维护成本** | 中（升级、备份 DB+`gitea-repositories/`） | 中（同 Gitea，但社区治理更去中心化） |
| **适合本项目度** | **★★★★☆** — 如果未来要给第二个客户/团队共享镜像，强烈推荐 | **★★★★☆** — 与 Gitea 等价，若反对 Gitea 商业化可选 |

> 二者**功能层面对镜像同步无实质差异**，选择主要看治理偏好和 Forgejo 独有的 SSH push mirror。

---

## 2. 话题 2 — systemd timer + `git remote update` 裸方案

### 2.1 最小可行方案（MVP）

**目录布局**：

```
/srv/git/
├── repo-a.git/   ← git clone --mirror https://github.com/owner/repo-a
├── repo-b.git/
└── ...
```

**`/etc/systemd/system/git-mirror@.service`**（实例化模板单元，`%i` = repo 名）：

```ini
[Unit]
Description=Mirror %i from GitHub
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
User=git
WorkingDirectory=/srv/git/%i.git
Environment=GIT_TERMINAL_PROMPT=0
# remote update 拉全部 ref；--prune 删本地多余 ref
ExecStart=/usr/bin/git remote update --prune
# dumb HTTP 客户端需要 info/refs；smart HTTP（CGI）则不需要
ExecStartPost=/usr/bin/git update-server-info
TimeoutStartSec=30min
```

**`/etc/systemd/system/git-mirror@.timer`**：

```ini
[Unit]
Description=Periodic mirror for %i

[Timer]
OnBootSec=5min
OnUnitActiveSec=15min       ; 每 15 分钟跑一次
RandomizedDelaySec=120      ; jitter，避免 N 个 timer 同时炸 GitHub
Persistent=true             ; 关机错过的 tick 在开机后补跑
Unit=git-mirror@%i.service

[Install]
WantedBy=timers.target
```

**启用**：

```bash
systemctl enable --now git-mirror@repo-a.timer
systemctl enable --now git-mirror@repo-b.timer
```

**关键 systemd 特性来源**（[systemd.timer(5)](https://www.freedesktop.org/software/systemd/man/latest/systemd.timer.html)）：

- `OnUnitActiveSec=` — 相对"上次激活完成"，自动避免重叠
- `RandomizedDelaySec=` — 在 0..N 秒内随机化，**Windows Task Scheduler 没有等价物**
- `Persistent=true` — 离线期间错过的触发会在开机后补跑（Windows TS 需要单独勾选"如未运行则尽快启动"）
- 失败重试：在 `[Service]` 加 `Restart=on-failure RestartSec=5min` 即可

### 2.2 vs Gitea Pull Mirror 对比

| 维度 | systemd timer + git | Gitea/Forgejo mirror |
|---|---|---|
| 资源占用 | **裸 git 内存 < 5 MB**，无常驻进程 | Gitea 主进程常驻 ~200 MB |
| 同步粒度 | 单仓库可独立配 timer，jitter 各异 | 全局 `DEFAULT_INTERVAL`，单仓库覆盖需 API |
| 失败告警 | systemd journal + `OnFailure=` 钩 mail/curl webhook | UI 红色提示，但需要登录看 |
| 增加新 repo | 1 行 `systemctl enable git-mirror@xxx.timer` + clone | UI 三步 |
| GitHub 凭据 | `~/.netrc` 或 `~/.git-credentials`，单文件 chmod 600 | 内置加密 |
| 监控 | `systemctl list-timers git-mirror@*` 一行所有状态 | UI/API |
| 协议层 | **完全靠下游 nginx 决定 smart/dumb**（见话题 3） | 由 Gitea HTTP server 自己实现 smart HTTP |

### 2.3 评分

| 指标 | 评分 |
|---|---|
| **实施复杂度** | **2**（2 个模板单元 + N 行 enable，~30 行 shell） |
| **维护成本** | **极低**（git/systemd 都不会变） |
| **适合本项目度** | **★★★★★** — 与 Windows 现状语义最贴近的迁移；如果只服务自己/小团队、不需要 Web 浏览，**首选**此方案；可与话题 3 的 smart HTTP 组合 |

---

## 3. 话题 3 — nginx/Caddy 服务 Smart HTTP (git-http-backend CGI) vs Dumb HTTP

### 3.1 协议层差异（官方原文）

**Pro Git 书 §10.6 Transfer Protocols**（[git-scm.com](https://git-scm.com/book/en/v2/Git-Internals-Transfer-Protocols)）：

> "The dumb protocol is fairly rarely used these days. It's difficult to secure or make private, so most Git hosts will refuse to use it. ... The smart protocol is a more common method ... it can read local data, figure out what the client has and needs, and **generate a custom packfile for it**."

| 维度 | Dumb HTTP（当前 Windows 方案） | Smart HTTP (`git-http-backend` CGI) |
|---|---|---|
| 服务端逻辑 | 纯静态文件 GET | CGI 子进程跑 `upload-pack`/`receive-pack` |
| 必需文件 | `info/refs` + `objects/info/packs`（靠 `git update-server-info` 生成） | 无（CGI 实时计算） |
| 协议版本 | 仅 v0 | **支持 v2**（设 `GIT_PROTOCOL` 即可，[git-http-backend(1)](https://git-scm.com/docs/git-http-backend)） |
| Ref 通告大小 | **全量 refs 在 `info/refs`，每次 fetch 都下载整份** | v2 `ls-refs` 支持 `ref-prefix` 过滤，可只取需要的分支 |
| 增量包 | 客户端拉松散对象 + 已有 pack；服务器不重组 | 服务端按客户端 `have` 列表生成最小 packfile |
| 大仓库典型表现 | 数百 MB repo 上**首次 clone 拉所有 pack（包括历史已过期的）**；增量 fetch 也要重新下载 `info/refs` | 首次 clone 拉单一最优 packfile；增量 fetch 只拉差异对象 |
| 推送支持 | 不支持 | 支持（`receive-pack`，需鉴权） |
| 缓存 | 静态文件易被反代缓存 | CGI 输出 `Cache-Control: no-cache`，反代缓存无意义 |

### 3.2 大仓库实测预期（基于协议机制推断）

> 没有公开权威 benchmark，以下为**协议层机制推导**，非实测数字：

| 仓库规模 | 操作 | Dumb HTTP | Smart HTTP v2 |
|---|---|---|---|
| 500 MB / 50k commits | 首次 `git clone` | 拉全部 pack 文件按目录列表逐个 GET（HTTP keep-alive 下 ~ 5–8 min @ 100 Mbps） | 单次 POST 收到一个 packfile（~3–5 min @ 100 Mbps，CPU 在服务端） |
| 同上 | 日常 `git fetch`（10 个新 commit） | 重新拉 `info/refs`（数百 KB）+ 缺失对象逐个 GET（**N+1 问题**，几十次 HTTP RTT） | 1 次 `ls-refs` + 1 次 `fetch`（2 个 HTTP POST，几 KB 增量包） |
| 2 GB / 200k commits（如 chromium 子集） | 首次 clone | **可能 30 min+**，受 HTTP 并发数限制 | 10–15 min，瓶颈在带宽 + 服务端 CPU |
| 同上 | 增量 fetch | refs 通告本身就几 MB | v2 `ref-prefix` 过滤后可能只传几十 KB |

**延迟敏感场景**：

- 单仓库 `git ls-remote`（CI 探测）：dumb 拉 `info/refs`（O(refs)），smart v2 用 `ls-refs ref-prefix=refs/heads/main` 只返回 1 个 ref
- 浅克隆 `git clone --depth=1`：**dumb 不支持**，必须 smart HTTP

### 3.3 nginx + fcgiwrap 配置范例

**架构**：nginx 收 HTTPS → fcgiwrap（FastCGI 包装器，把 CGI 包成持久 socket）→ `git-http-backend`

```nginx
# /etc/nginx/conf.d/git.conf
server {
    listen 443 ssl http2;
    server_name git.example.com;

    # ... ssl_certificate, ssl_certificate_key ...

    location ~ ^/git/(.*)$ {
        # 可选：basic auth / TLS 客户端证书
        # auth_basic "Git Repos";
        # auth_basic_user_file /etc/nginx/git.htpasswd;

        client_max_body_size 0;            # 大 push 不要限制
        fastcgi_buffering off;             # smart protocol 流式
        fastcgi_request_buffering off;

        fastcgi_pass unix:/run/fcgiwrap.socket;
        fastcgi_param SCRIPT_FILENAME     /usr/lib/git-core/git-http-backend;
        fastcgi_param PATH_INFO           /$1;
        fastcgi_param GIT_PROJECT_ROOT    /srv/git;
        fastcgi_param GIT_HTTP_EXPORT_ALL "";
        fastcgi_param GIT_PROTOCOL        $http_git_protocol;  # v2 协商
        fastcgi_param REMOTE_USER         $remote_user;
        include       fastcgi_params;
    }
}
```

**关键点**：

- `fastcgi_buffering off` — smart protocol 是流式协议，缓冲会阻塞 sideband 进度条
- `client_max_body_size 0` — 允许大 push（receive-pack）
- `GIT_PROTOCOL $http_git_protocol` — 启用 v2，**这是性能关键**
- 客户端默认 v2：`git config --global protocol.version 2`（git ≥ 2.26 默认）

### 3.4 Caddy 等价方案

Caddy 没有内置 FastCGI 反代到 CGI 二进制的便捷指令，但可以用 `reverse_proxy` + `fcgiwrap`：

```caddy
git.example.com {
    handle /git/* {
        reverse_proxy unix//run/fcgiwrap.socket {
            transport fastcgi {
                root /srv/git
                env GIT_PROJECT_ROOT /srv/git
                env GIT_HTTP_EXPORT_ALL ""
                env SCRIPT_FILENAME /usr/lib/git-core/git-http-backend
            }
        }
    }
}
```

> Caddy 优势：**自动 Let's Encrypt**；劣势：FastCGI 文档比 nginx 稀缺。

### 3.5 评分

| 方案 | 实施复杂度 | 维护成本 | 适合本项目度 |
|---|---|---|---|
| **保持 Dumb HTTP（迁移到 Linux nginx）** | **1** — 一个 `location { autoindex on; }` | 极低 | ★★★☆☆ — 仓库 < 100 MB 且只读、内网时可用 |
| **Smart HTTP + nginx + fcgiwrap** | **3** — 装 fcgiwrap、写 7 行 nginx env、调 buffering | 低（fcgiwrap 极稳） | **★★★★★** — 一旦仓库 > 200 MB 或要 push，必选 |
| **Smart HTTP + Caddy + fcgiwrap** | **3** — 与 nginx 同复杂度，TLS 自动化 | 低 | ★★★★☆ — 域名 + ACME 自动续期场景下更省心 |
| **Gitea/Forgejo 自带 HTTP（不走 git-http-backend）** | **2** — 装包即用 | 中（升级负担） | ★★★★☆ — 同时拿到 smart HTTP + Web UI，但内存开销大 |

---

## 4. 综合横向对比

| 方案 | 实施复杂度（1–5） | 维护成本 | 大仓库性能 | 适合本项目度 |
|---|---|---|---|---|
| A. systemd timer + dumb HTTP nginx | 2 | 极低 | 差（不推荐） | ★★☆☆☆ |
| **B. systemd timer + Smart HTTP (nginx + fcgiwrap)** | **3** | **低** | **优** | **★★★★★** — 与 Windows 现状最对称的升级 |
| C. systemd timer + Caddy + fcgiwrap | 3 | 低（TLS 自动） | 优 | ★★★★☆ |
| **D. Gitea v1.26 容器（自带 smart HTTP + 内置 mirror）** | **2** | **中** | **优** | **★★★★★** — 未来要给多人共享 / 要 Web UI 时首选 |
| E. Forgejo v15 容器 | 2 | 中 | 优 | ★★★★☆ — 与 D 等价，治理偏好分歧时选 |
| F.（当前 baseline）Windows 计划任务 + dumb HTTP | 1 | 中（手工度高） | 差 | ★★☆☆☆ |

### 推荐路径

**短期（与现状语义对称迁移）**：方案 **B**

- 把 Windows 的 `git clone --mirror` + 计划任务 1:1 翻译成 systemd timer
- 把 dumb HTTP（IIS 静态）换成 nginx + fcgiwrap + git-http-backend，**立刻获得 smart HTTP v2**
- 风险面最小，回滚就是改 nginx 一段 location

**中期（团队/多用户场景）**：方案 **D / E**

- 一旦需要 token 隔离、Web 浏览、PR/issue、LFS，迁到 Gitea/Forgejo
- 镜像逻辑变成 UI 配置，systemd timer 退役

---

## 5. Caveats / Not Found

- **Smart HTTP vs Dumb HTTP 的具体 benchmark 数字**：未找到 2024+ 的公开实测对比；上述延迟差异为**协议机制推导**，建议本项目自己跑一次：用 `git -c protocol.version=0 clone $URL` 和 `git -c protocol.version=2 clone $URL` 对比 wall-clock。
- **Gitea Pull Mirror 在 GitHub 限速下的行为**：官方文档未说明遇到 403/429 时的退避策略，需要看 `gitea-repositories/` 旁的 `mirror.log` 验证（不在本次任务范围）。
- **Forgejo / Gitea 的 SSH push mirror 差异**：Forgejo 用户 doc 明确写 "LFS over SSH protocol is not implemented in Forgejo, any LFS objects will not be mirrored"，Gitea 同上但未明示；如果仓库含 LFS，必须用 HTTPS。
- **fcgiwrap 与 spawn-fcgi 选型**：未深入对比；fcgiwrap 在 Debian/Ubuntu 包仓库可用、零配置，是最常见选择。
- **rate limit 与 token 轮换**：未调研 GitHub PAT 的 fine-grained token 在 mirror 场景下的最小权限集（推断 `contents:read` 足够，需自验）。

---

## 6. 决定性引用

1. [docs.gitea.com/usage/repo-mirror](https://docs.gitea.com/usage/repo-mirror) — Gitea Pull Mirror UI 流程
2. [docs.gitea.com/administration/config-cheat-sheet](https://docs.gitea.com/administration/config-cheat-sheet) — `[mirror]` 段 `DEFAULT_INTERVAL=8h` / `MIN_INTERVAL=10m`，`HTTP_PORT=3000`、`SSH_PORT=22`
3. [forgejo.org/docs/latest/user/repo-mirror](https://forgejo.org/docs/latest/user/repo-mirror/) — Forgejo Pull Mirror，含 SSH push mirror
4. [git-scm.com/docs/git-http-backend](https://git-scm.com/docs/git-http-backend) — smart/dumb 都支持；v2 协议靠 `GIT_PROTOCOL` 环境变量启用
5. [git-scm.com/book/en/v2/Git-Internals-Transfer-Protocols](https://git-scm.com/book/en/v2/Git-Internals-Transfer-Protocols) — Pro Git 书原文："The dumb protocol is fairly rarely used these days"
6. [git-scm.com/docs/git-update-server-info](https://git-scm.com/docs/git-update-server-info) — dumb HTTP 必须 `info/refs` + `objects/info/packs`
7. [git-scm.com/docs/protocol-v2](https://git-scm.com/docs/protocol-v2) — `ls-refs` + `ref-prefix` 减少通告
8. [freedesktop.org/software/systemd/man/latest/systemd.timer.html](https://www.freedesktop.org/software/systemd/man/latest/systemd.timer.html) — `OnUnitActiveSec=`、`RandomizedDelaySec=`、`Persistent=true`
9. [nginx.org/en/docs/http/ngx_http_fastcgi_module.html](https://nginx.org/en/docs/http/ngx_http_fastcgi_module.html) — `fastcgi_pass` / `fastcgi_param`
10. GitHub Releases API (2026-05-19 实查) — Gitea v1.26.1 / Forgejo v15.0.2
