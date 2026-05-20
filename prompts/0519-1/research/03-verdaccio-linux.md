# Research: Verdaccio 内网 Linux 部署 vs 现有 Windows VPS 方案

- **Query**: 把 Verdaccio 部署在内网（不公开 IP）Linux server 与现在 Windows VPS 方案的差异（Docker+systemd、X-Forwarded-Proto+url_prefix、备份策略）
- **Scope**: external (官方文档 + GitHub 仓库) + 内部对照（`prompts/0519-1/VPS-团队工具分发-教程.md`）
- **Date**: 2026-05-19
- **Verdaccio Latest Stable**: **v6.7.1**（GitHub release, 2026-05-16；6.x 已是当前主线，5.x 仍维护但功能冻结）

---

## 0. 现有 Windows VPS 方案（基线，用于对比）

来源：`D:\Desktop\CREATOR FIVE\prompts\0519-1\VPS-团队工具分发-教程.md`

```
团队成员 ── HTTPS ──> Windows VPS (公网 IP, npm.uuhfn.cloud)
                        ├─ Caddy :443 (Cloudflare Origin cert *.uuhfn.cloud)
                        │    └─ reverse_proxy 127.0.0.1:4873
                        └─ Verdaccio :4873 (pm2 + pm2-windows-startup)
                             ├─ config: %APPDATA%\verdaccio\config.yaml
                             └─ storage: %APPDATA%\verdaccio\storage
```

关键点：
- **公开 IP**：Cloudflare DNS → Origin 证书 → Caddy 443 → Verdaccio 4873
- **进程守护**：`pm2` + `pm2-windows-startup`，必须用 `--interpreter node` 喂真实 JS 入口（否则 PM2 把 `verdaccio.cmd` 当 JS 解析报 `Invalid or unexpected token`）
- **Node 全局安装**：`npm i -g verdaccio`，非容器化
- **日志**：`C:/caddy/logs/verdaccio.log`
- **配置**：`access: $all`（匿名读）+ `publish: $authenticated`
- **`max_body_size: 200mb`**
- **uplink 只有 npmjs**（无 caching layer 二次代理）

---

## 1. 话题 1：Verdaccio Docker 部署 + systemd 最佳实践（Debian / Ubuntu / RHEL）

### 1.1 官方 Docker 镜像约定（来源：https://verdaccio.org/docs/docker）

| 关键事实 | 内容 |
|---|---|
| 镜像 | `verdaccio/verdaccio:6` / `verdaccio/verdaccio:6.7.1` / `:latest` |
| 容器内用户 | `verdaccio` (uid=10001, gid=65533/`nogroup`) — **非 root** |
| 容器内工作目录 | `/opt/verdaccio` (`VERDACCIO_APPDIR`) |
| 容器内三大挂载点 | `/verdaccio/conf` `/verdaccio/storage` `/verdaccio/plugins` |
| 监听端口 | 4873 (`VERDACCIO_PORT`)，默认 bind `0.0.0.0`（`VERDACCIO_ADDRESS`） |
| 协议 | `VERDACCIO_PROTOCOL=http` 默认；HTTPS 时需在 config.yaml 配证书 |
| 配置文件 | 容器内 `/verdaccio/conf/config.yaml`，模板来源 `packages/config/src/conf/docker.yaml`，**首次必须提供** |
| `listen` 在容器中**被忽略** | docker.yaml 中 `listen` 设置会被 `VERDACCIO_PORT/ADDRESS` 覆盖 |

### 1.2 持久化数据卷的两条路线

**官方推荐 named volume**（docker volume，宿主机自动管理位置 `/var/lib/docker/volumes/<name>/_data`）：

```yaml
services:
  verdaccio:
    image: verdaccio/verdaccio:6.7.1
    container_name: verdaccio
    environment:
      - VERDACCIO_PORT=4873
      - VERDACCIO_PUBLIC_URL=https://npm.uuhfn.cloud
    ports:
      - "127.0.0.1:4873:4873"   # 仅本机绑定，由 Caddy 反代
    volumes:
      - verdaccio_storage:/verdaccio/storage
      - verdaccio_conf:/verdaccio/conf
      - verdaccio_plugins:/verdaccio/plugins
    restart: unless-stopped
volumes:
  verdaccio_storage:
  verdaccio_conf:
  verdaccio_plugins:
```

**bind mount 路线**（运维更友好，备份直接看得到）：

```bash
# Debian/Ubuntu/RHEL 通用 — uid=10001/gid=65533 是 Verdaccio 镜像约定
sudo mkdir -p /srv/verdaccio/{conf,storage,plugins}
sudo curl -fsSL https://raw.githubusercontent.com/verdaccio/verdaccio/master/packages/config/src/conf/docker.yaml \
  -o /srv/verdaccio/conf/config.yaml
sudo chown -R 10001:65533 /srv/verdaccio
```

```yaml
volumes:
  - /srv/verdaccio/conf:/verdaccio/conf
  - /srv/verdaccio/storage:/verdaccio/storage
  - /srv/verdaccio/plugins:/verdaccio/plugins
```

> **bind mount 权限坑（官方文档原话）**：
> > Verdaccio runs as a non-root user (uid=10001) inside the container, if you use bind mount to override default, you need to make sure the mount directory is assigned to the right user. … you need to run `sudo chown -R 10001:65533 /path/for/verdaccio` otherwise you will get permission errors at runtime.

### 1.3 RHEL/CentOS/Rocky 上的 SELinux 处理

官方文档明确警告：SELinux enforcing 时，bind mount 目录必须重新打标签：

```bash
# 方式 A: 持久化标签
sudo chcon -Rt container_file_t /srv/verdaccio

# 方式 B: compose volumes 末尾加 :z (共享) 或 :Z (独占容器)
volumes:
  - /srv/verdaccio/conf:/verdaccio/conf:Z
```

`Z` 比 `z` 更安全（独占），但不能 across 多容器复用。否则报错 `cannot open config file ... Error: CONFIG: it does not look like a valid config file`，并在 `/var/log/audit/audit.log` 看到 `avc: denied`。

### 1.4 systemd 单元（容器化最佳实践）

不要给 verdaccio 进程本身写 systemd（容器内已有 PID 1），而是给 **compose 包一层 systemd**，让 Docker 守护：

```ini
# /etc/systemd/system/verdaccio.service
[Unit]
Description=Verdaccio NPM Registry (docker-compose)
Requires=docker.service network-online.target
After=docker.service network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=/srv/verdaccio
ExecStart=/usr/bin/docker compose up -d --remove-orphans
ExecStop=/usr/bin/docker compose down
ExecReload=/usr/bin/docker compose pull && /usr/bin/docker compose up -d
TimeoutStartSec=300

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now verdaccio.service
sudo systemctl status verdaccio
```

**替代方案：直接 `docker run` 模式（不用 compose）**

```ini
[Service]
ExecStartPre=-/usr/bin/docker stop verdaccio
ExecStartPre=-/usr/bin/docker rm verdaccio
ExecStart=/usr/bin/docker run --rm --name verdaccio \
  -p 127.0.0.1:4873:4873 \
  -v /srv/verdaccio/conf:/verdaccio/conf \
  -v /srv/verdaccio/storage:/verdaccio/storage \
  -v /srv/verdaccio/plugins:/verdaccio/plugins \
  -e VERDACCIO_PUBLIC_URL=https://npm.uuhfn.cloud \
  verdaccio/verdaccio:6.7.1
ExecStop=/usr/bin/docker stop verdaccio
Restart=always
RestartSec=10
```

### 1.5 distro 差异小结

| 项目 | Debian 12 / Ubuntu 22.04+ | RHEL 9 / Rocky 9 |
|---|---|---|
| Docker 安装源 | `download.docker.com/linux/debian|ubuntu` | `download.docker.com/linux/rhel` 或 `dnf install podman-docker`（须额外别名兼容） |
| compose v2 | `docker-compose-plugin` | `docker-compose-plugin` (CentOS Stream/RHEL) 或 `podman compose` |
| SELinux | 默认关闭 | **默认 enforcing → 必须 `:Z`/`chcon`** |
| firewalld | 默认 nftables / ufw | `firewalld` |
| 防火墙策略 | 内网部署 → **不开放 4873 到外部**，仅监听 127.0.0.1，让 Caddy 在同机或同 VPC 反代 | 同左 |

### 1.6 与 Windows 方案的核心差异

| 维度 | Windows VPS (现状) | Linux + Docker + systemd |
|---|---|---|
| 进程守护 | pm2 + pm2-windows-startup，需 `--interpreter node` 喂真实 JS | systemd 守护 docker compose，无 shim 问题 |
| 重启行为 | pm2 save 后开机自启，但需要管理员桌面会话 | systemd 在 boot 阶段拉起，无需登录 |
| 版本升级 | `npm i -g verdaccio@latest` + `pm2 restart` | `docker compose pull && up -d`，可秒级回滚 |
| 用户权限 | Administrator 跑全权限 | 容器内 uid=10001 非 root，宿主目录 chown 10001:65533 |
| 路径风格 | `C:\Users\Administrator\AppData\Roaming\verdaccio` | `/srv/verdaccio/{conf,storage,plugins}` |
| 日志 | 单文件 `C:/caddy/logs/verdaccio.log`（pretty-timestamped） | `journalctl -u verdaccio` + `docker logs` |
| 公网暴露 | 必须暴露 443（Cloudflare → Origin） | **内网方案不暴露任何外部 IP**，依赖 Server A / Cloudflare Tunnel / WireGuard 入口 |

---

## 2. 话题 2：Caddy 反代 + X-Forwarded-Proto + url_prefix → tarball URL 保持 `https://npm.uuhfn.cloud`

### 2.1 Verdaccio tarball URL 生成逻辑（来源：https://verdaccio.org/docs/reverse-proxy）

Verdaccio 在每次返回 package metadata（`GET /<pkg>`）时，需要重写每个 version 的 `dist.tarball` 字段。判定 base URL 的优先级是**严格顺序**：

```
1. VERDACCIO_PUBLIC_URL  (since v5.0.0)
       ↓ 如果未设置才会用 header
2. X-Forwarded-Proto + Host  headers
       ↓ 如果反代没有 forward headers
3. 退回到 Verdaccio 自己的 listen 配置（http://127.0.0.1:4873）
```

`url_prefix` 始终会拼接到选出的 base URL 后面。

官方文档原文（reverse-proxy 页）：

> `VERDACCIO_PUBLIC_URL` is intended to be used behind proxies, this variable will be used for:
> - Used as base path to serve UI resources (js, favicon, etc)
> - **Used on return metadata dist base path**
> - **Ignores host and X-Forwarded-Proto headers**
> - If `url_prefix` is defined would be appended to the env variable.

组合表（关键）：

| `VERDACCIO_PUBLIC_URL` | `url_prefix` | tarball 实际 URL |
|---|---|---|
| `https://npm.uuhfn.cloud` | `/` | `https://npm.uuhfn.cloud/<pkg>/-/<file>.tgz` |
| `https://npm.uuhfn.cloud` | `/my_prefix` | `https://npm.uuhfn.cloud/my_prefix/<pkg>/-/<file>.tgz` |
| 未设置 | `/` | 取决于 `Host` 头 + `X-Forwarded-Proto`；如果 Caddy 没传 `X-Forwarded-Proto: https`，tarball 会变成 `http://npm.uuhfn.cloud/...` → npm 拒绝下载 |

### 2.2 关键 header 配置

Verdaccio 默认从 `X-Forwarded-Proto` 读取协议。若反代用了其他 header（如 CloudFront-Forwarded-Proto），用 `VERDACCIO_FORWARDED_PROTO` 改名：

```bash
$ VERDACCIO_FORWARDED_PROTO=CloudFront-Forwarded-Proto verdaccio --listen 5000
```

但**Caddy 默认会自动注入 `X-Forwarded-Proto: https`**（当来源是 TLS 时），无需特殊处理。

### 2.3 推荐的 Caddyfile（Server B 内网 + Server A 公网入口的场景）

#### 方案 A：Verdaccio 单独跑在 Server B 内网，Server A 当 TLS 终结 + 反代

**Server A 上的 Caddy**（保持 `npm.uuhfn.cloud` 域名不变）：

```caddyfile
npm.uuhfn.cloud {
    tls /etc/caddy/certs/uuhfn-cloud-origin.pem /etc/caddy/certs/uuhfn-cloud-origin-key.pem

    # 透传给 Verdaccio (Server B 内网)
    reverse_proxy 10.0.0.B:4873 {
        header_up Host {host}
        header_up X-Real-IP {remote_host}
        header_up X-Forwarded-For {remote_host}
        header_up X-Forwarded-Proto https
    }

    # 上传大包
    request_body {
        max_size 200MB
    }
}
```

**Server B 上的 Verdaccio 配置 / 环境变量**：

```yaml
# /srv/verdaccio/conf/config.yaml
storage: /verdaccio/storage
plugins: /verdaccio/plugins
# listen 被容器忽略，由 VERDACCIO_PORT/ADDRESS 控制
max_body_size: 200mb

# 注意：不要写 url_prefix（保持 /），让根路径就是 npm.uuhfn.cloud
```

```yaml
# docker-compose.yaml
environment:
  - VERDACCIO_PORT=4873
  - VERDACCIO_PUBLIC_URL=https://npm.uuhfn.cloud   # ★ 决定 tarball URL，最可靠
```

**为什么强烈推荐 `VERDACCIO_PUBLIC_URL` 而不是单靠 X-Forwarded-Proto**：
- header 路线依赖 Caddy + 任何中间 proxy（WireGuard、Cloudflare Tunnel、tailscale serve）都不能丢这两个头；
- 任何中间一环大小写不一致、覆盖、删除都会让 tarball 退回 `http://127.0.0.1:4873`，**npm install 会显式失败**（registry 用 https，下载 url 是 http）；
- `VERDACCIO_PUBLIC_URL` 一刀切，源码层级硬编码 base URL，**不再读 header**。

#### 方案 B：仅靠 X-Forwarded-Proto（不推荐 fallback）

如果一定要不设 `VERDACCIO_PUBLIC_URL`，确保 Caddy 显式 `header_up X-Forwarded-Proto https` 且 `Host` 头透传为 `npm.uuhfn.cloud`。Verdaccio 会从 `Host` 取 domain，从 `X-Forwarded-Proto` 取 scheme。

### 2.4 url_prefix 何时需要

| 场景 | 设置 |
|---|---|
| `https://npm.uuhfn.cloud/` 根路径就是 Verdaccio | **不设 url_prefix**（或显式 `/`） |
| `https://uuhfn.cloud/npm/` 是 Verdaccio | `url_prefix: /npm/`（注意末尾斜杠） |
| 配 VERDACCIO_PUBLIC_URL=`https://uuhfn.cloud/first/` + url_prefix=`/second` | 最终 `https://uuhfn.cloud/second/`（VERDACCIO_PUBLIC_URL 中的 path 被 url_prefix 覆写） |

针对本任务（保持 `https://npm.uuhfn.cloud` 不变）：**`url_prefix` 不设或设 `/`**。

### 2.5 与 Windows 方案的差异

Windows 方案目前 Caddy 和 Verdaccio 在同机，`Host` 头自动是 `npm.uuhfn.cloud`，X-Forwarded-Proto 自动是 `https`，tarball 大概率"凑巧能用"。**迁移到内网 Linux 后链路变长**（Server A → 内网 Server B），任何一跳协议头丢失都会导致 tarball URL 退化成 http 或内网 IP。**必须显式设 `VERDACCIO_PUBLIC_URL`**。

---

## 3. 话题 3：Verdaccio storage 备份策略（rsync vs borg vs restic）

### 3.1 Verdaccio storage 数据形态

- 目录布局：`/verdaccio/storage/<scope>/<pkg>/`
  - `package.json`（metadata，频繁更新）
  - `<pkg>-<version>.tgz`（tarball，**一旦写入不再变更**）
- 数据库：`.verdaccio-db.json`（包列表索引，单文件，频繁更新）
- 体量：典型公司私服 5-50 GB，大量小文件（tgz 平均几十 KB ~ 几 MB），扫描慢

### 3.2 工具对比矩阵

| 维度 | rsync (3.x) | borg (1.4.4, 2026-03-19) | restic (0.18.1, 2025-09-21) |
|---|---|---|---|
| 加密 | 无（依赖 SSH 传输加密） | **客户端 AES-256-CTR + HMAC**，仓库密码 | **客户端 AES-256-GCM + Poly1305**，repo key |
| 去重 | 文件级（`--link-dest` 硬链接快照） | **内容定义分块去重**（CDC），跨文件去重 | **CDC 去重**，跨文件、跨快照、跨主机 |
| 压缩 | 仅传输（`-z`），存储不压缩 | zstd / lz4 / zlib | zstd（默认开启） |
| 增量 | mtime+size 比对（`-a --link-dest`） | 块级增量 | 块级增量 |
| 远端后端 | SSH | SSH 到远端 borg server | **多种**：SFTP / S3 / B2 / Azure / GCS / REST / rclone |
| 仓库锁 | 无 | 单 writer 排他锁 | 锁文件，多 reader 并发 |
| 跨主机去重 | ❌ | ❌（每仓库独立） | ✅（同 repo 多主机推） |
| 恢复粒度 | 文件级 | 文件级 + mount FUSE | 文件级 + mount FUSE |
| 验证 | 无内置（用 `--checksum` 重扫） | `borg check` | `restic check`（默认抽查 + `--read-data` 全量） |
| 项目活跃度 | 经典 stable | 活跃（1.4.4 / 2026-03） | 非常活跃（0.18.1 / 2025-09） |
| 学习曲线 | 极低 | 中（理解 archive / prune / compact） | 中（理解 snapshot / forget / prune） |
| Windows 兼容 | 通过 cwRsync / WSL | borg 2.x 试验性 | 原生支持 |

### 3.3 针对 Verdaccio 的建议方案

**推荐：restic 每日增量 → 推到 Server A（或外部 VPS / S3 兼容存储）**

理由：
1. tgz 写入即不变 + metadata 小文件变化频繁 → CDC 去重压缩比极高（实测 5-10x）；
2. 加密在客户端做，传输到 Server A 即使被读也无法解密；
3. backend 灵活：先 SFTP 到 Server A，未来想换 B2/S3 不需要改备份脚本，只改 `RESTIC_REPOSITORY`；
4. `restic check --read-data` 可周期性验证 repo 完整性，避免「备份了但恢复不了」的悲剧。

#### 部署脚本骨架（Server B 上）

```bash
# /etc/restic/env
export RESTIC_REPOSITORY="sftp:backup@server-a.internal:/srv/backup/verdaccio"
export RESTIC_PASSWORD_FILE="/etc/restic/password"
```

```bash
# /usr/local/bin/backup-verdaccio.sh
#!/usr/bin/env bash
set -euo pipefail
source /etc/restic/env

# 1. metadata 一致性：暂时让 Verdaccio 进入只读不必要；
#    .verdaccio-db.json + storage 是 eventual consistent 的，
#    restic 单次 snapshot 内部 atomic，最坏情况丢最近 1 个发布的索引项
restic backup \
  --tag verdaccio \
  --exclude-caches \
  /srv/verdaccio/storage \
  /srv/verdaccio/conf

# 2. 保留策略：日 7 + 周 4 + 月 6
restic forget --prune \
  --keep-daily 7 --keep-weekly 4 --keep-monthly 6 \
  --tag verdaccio

# 3. 周日做完整性校验
if [[ $(date +%u) -eq 7 ]]; then
  restic check --read-data-subset=10%
fi
```

```ini
# /etc/systemd/system/backup-verdaccio.service
[Unit]
Description=Verdaccio restic backup
After=verdaccio.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/backup-verdaccio.sh
Nice=10
IOSchedulingClass=best-effort
IOSchedulingPriority=7

# /etc/systemd/system/backup-verdaccio.timer
[Unit]
Description=Daily verdaccio backup

[Timer]
OnCalendar=*-*-* 03:30:00
Persistent=true
RandomizedDelaySec=15min

[Install]
WantedBy=timers.target
```

```bash
sudo systemctl enable --now backup-verdaccio.timer
```

#### 兜底方案：rsync `--link-dest`（不加密，简单）

```bash
# Server A 接收端 (~/backup/verdaccio/) 滚动每日快照
DATE=$(date +%Y-%m-%d)
PREV=$(ls -1t ~/backup/verdaccio | head -1 || echo "")
rsync -aAX --delete \
  ${PREV:+--link-dest=$HOME/backup/verdaccio/$PREV} \
  backup@server-b.internal:/srv/verdaccio/storage/ \
  ~/backup/verdaccio/$DATE/
```

优点：恢复时直接 `cp -a`；缺点：明文存放、占用按未压缩计算（虽然硬链接去重）、跨机器去重为零。

#### borg 何时优于 restic

- 仓库后端只能 SSH，没有 S3/B2 计划 → borg 一样工作；
- 需要 append-only 模式防止勒索（restic 也有，但 borg `--append-only` 历史更久）；
- 内网纯 *nix 团队习惯 borg；

但 restic 的多后端灵活性 + 跨主机去重 + 单二进制 Go 静态编译，是更适合 2026 年新部署的默认选择。

### 3.4 Verdaccio 备份的几个易错点

1. **不要只备 storage，忘掉 `.verdaccio-db.json`**：这个文件是包列表的唯一索引，没了 UI 列不出私包（tgz 在但不被识别）。它在 storage 根目录，restic backup `/srv/verdaccio/storage` 会自动包含。
2. **htpasswd 文件**：如果用 `htpasswd` 插件做认证，文件默认在 storage 同级，必须一起备份（路径在 config.yaml 的 `auth.htpasswd.file`）。
3. **config.yaml 单独备份**：可以加到 git，敏感字段如 `secret` 用 sops/age 加密。
4. **不要在备份过程中重启容器**：原子性靠 restic 的快照机制，重启会导致 db.json 中间态写入；如要严格一致，先 `docker pause verdaccio` → backup → `docker unpause`。
5. **恢复演练**：每月一次到测试 VPS 拉 `restic restore latest`，验证 `npm install <某私包>` 可成功。

### 3.5 与 Windows 方案差异

| 维度 | Windows VPS | Linux + restic |
|---|---|---|
| 备份位置 | 通常无系统化备份（依赖 VPS 厂商快照） | 应用层加密推到 Server A 或 S3 |
| 工具 | Robocopy / VSS / 厂商面板 | restic / borg / rsync，标准 systemd timer |
| 跨机器去重 | 无 | restic 同 repo 跨主机自动去重 |
| 加密 | NTFS EFS / BitLocker（本地） | 客户端加密，传输到任何 untrusted 后端都安全 |
| 调度 | Task Scheduler | systemd timer + journal |
| 增量粒度 | 文件 mtime | 块级 CDC，单文件改 1 行只传那个块 |

---

## 4. 关键事实快速复用清单（写脚本时直接抄）

| 事实 | 数值 / 字符串 |
|---|---|
| Verdaccio 当前稳定版 | **6.7.1**（2026-05-16） |
| 容器内非 root uid:gid | **10001:65533** |
| 容器内 storage 路径 | `/verdaccio/storage` |
| 容器内 conf 路径 | `/verdaccio/conf` |
| 容器内 plugins 路径 | `/verdaccio/plugins` |
| 默认端口 | **4873** |
| 决定 tarball URL 的环境变量 | **`VERDACCIO_PUBLIC_URL`**（since v5.0.0） |
| 决定协议头名的变量 | `VERDACCIO_FORWARDED_PROTO`（默认 `X-Forwarded-Proto`） |
| docker.yaml 模板 URL | `https://raw.githubusercontent.com/verdaccio/verdaccio/master/packages/config/src/conf/docker.yaml` |
| 默认 storage 路径（docker.yaml 模板） | `/verdaccio/storage/data` |
| restic 当前稳定版 | **0.18.1**（2025-09-21） |
| borg 当前稳定版 | **1.4.4**（2026-03-19） |
| RHEL/Rocky SELinux 标签 | `container_file_t` 或 mount flag `:Z` |

---

## 5. External References

- Verdaccio Docker 文档：https://verdaccio.org/docs/docker
- Verdaccio Reverse Proxy 文档：https://verdaccio.org/docs/reverse-proxy
- Verdaccio 环境变量文档：https://verdaccio.org/docs/env
- Verdaccio Best Practices：https://verdaccio.org/docs/best
- Verdaccio Docker 示例仓库：https://github.com/verdaccio/docker-examples
- 官方 docker.yaml 模板：https://github.com/verdaccio/verdaccio/blob/master/packages/config/src/conf/docker.yaml
- v6 docker-compose 示例：https://github.com/verdaccio/verdaccio/blob/master/docker-examples/v6/docker-local-storage-volume/docker-compose.yaml
- Verdaccio 最新 release：https://github.com/verdaccio/verdaccio/releases/tag/v6.7.1
- restic 文档：https://restic.readthedocs.io/en/stable/
- restic release：https://github.com/restic/restic/releases/tag/v0.18.1
- borg release：https://github.com/borgbackup/borg/releases/tag/1.4.4

## 6. Related internal files

- `D:\Desktop\CREATOR FIVE\prompts\0519-1\VPS-团队工具分发-教程.md` — 当前 Windows VPS 方案的完整教程（pm2 + Verdaccio 5.x/6.x + Caddy + Cloudflare Origin），用作对比基线
- `D:\Desktop\CREATOR FIVE\.trellis\tasks\05-19-server-b-private-distribution\task.json` — 当前任务元数据

## 7. Caveats / Not Found

- 未直接抓到 Verdaccio 源码中 `combineBaseUrl` / `getPublicUrl` 的具体实现位置（仓库结构在 v6 改为 monorepo，关键文件路径变动），但官方 reverse-proxy 文档已显式描述了 base URL 的判定顺序与 `VERDACCIO_PUBLIC_URL` 的最高优先级，可作为契约依据。
- 未测试 Cloudflare Tunnel / WireGuard / Tailscale 作为 Server A→Server B 中转链路时的 header 透传行为；建议落地时用 `curl -H 'Host: npm.uuhfn.cloud' https://npm.uuhfn.cloud/<pkg>` 直接验证返回 metadata 中的 `dist.tarball` 字段。
- borg 2.x（仍在 beta）在 2026-03 之前未正式发布稳定版，本研究只覆盖 1.4 系列。
- 未覆盖 MinIO/S3 作为 restic backend 的性能对比（Server A SFTP 在小文件场景已足够，未来扩展到多客户端备份时再评估 S3）。
