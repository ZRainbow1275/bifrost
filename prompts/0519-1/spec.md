# SPEC v2 — Bifrost Server B 私有分发栈技术规范

> **Bound PRD**: `prd.md` (D1-D5 锁定) ｜ **Review**: `spec-review.md` (28 findings 已处理)
> **Status**: design-frozen v2 | **Updated**: 2026-05-19

> v2 变更概览：修 5🔴+18🟠+5🟡（详见 `spec-review.md`）。新增 AC-11/12/13；NewAPI PG 配置依 `research/04-newapi-postgres.md` 落实。

---

## 0. 总览

```
                       INTERNET
                           |
                           v
              ┌────────────────────────────┐
              │  Cloudflare DNS (灰云)     │
              │  *.uuhfn.cloud → A 公网 IP │
              └────────────┬───────────────┘
                           v
  ┌──────────────────── SERVER A (国内云) ────────────────────┐
  │  公网入站：80/tcp 443/tcp（Caddy）+ 22/tcp +51820/udp(WG) │
  │  Caddy (TLS 终止，私钥集中)                                │
  │    ├─ api.uuhfn.cloud  ──► http://10.8.0.2:3000           │
  │    ├─ npm.uuhfn.cloud  ──► http://10.8.0.2:4873           │
  │    ├─ files.uuhfn.cloud ──► http://10.8.0.2:8081          │
  │    │      └─ /git/*    ──► http://10.8.0.2:8082           │
  │    └─ legacy.uuhfn.cloud（IP HTTPS 兼容，保留）           │
  │  bifrost-api (127.0.0.1:8000) + /mirrors/* 只读路由       │
  │  WireGuard hub  wg0=10.8.0.1/24  endpoint :51820          │
  └────────────────────────┬──────────────────────────────────┘
                           |  wg tunnel
                           v
  ┌──────────────────── SERVER B (海外) ──────────────────────┐
  │  公网入站：22/tcp (双通道) + 51820/udp，其它 DROP          │
  │  wg0 = 10.8.0.2/24  所有镜像服务只 bind 此接口            │
  │    Caddy on wg0:8081 (files) + :8082 (git read-only)      │
  │    Verdaccio (docker) wg0:4873                            │
  │    NewAPI (docker compose) wg0:3000 + PG15 + Redis        │
  │    Xray VLESS+Reality (公网 8443，现状)                   │
  │  systemd timer: git-mirror@*.timer / verdaccio-backup     │
  │  systemd timer: restic-to-a.timer (推备份回 A)            │
  └────────────────────────────────────────────────────────────┘
```

---

## 1. IP / 端口 / 服务清册

### 1.1 Server B 服务清单

| 服务 | 接口 | 端口 | 进程 | 持久化 |
|---|---|---|---|---|
| WireGuard | eth0 (公网) | 51820/udp | kernel wg | `/etc/wireguard/wg0.conf` |
| SSH | eth0 + wg0 | 22/tcp | sshd | systemd |
| Caddy (mirrors) | wg0 | 8081 (files), 8082 (git) | caddy.service | `/etc/caddy/Caddyfile` |
| Verdaccio | wg0 | 4873 | docker `verdaccio/verdaccio:6.7.1` | `/var/lib/verdaccio/{storage,config}` |
| NewAPI app | wg0 | 3000 | docker `calciumion/new-api:v1.0.0-rc.6` | `/var/lib/new-api/data` |
| PostgreSQL 15 | docker 内网 | 5432 | docker `postgres:15` | `/var/lib/new-api-pg` |
| Redis 7 | docker 内网 | 6379 | docker `redis:7-alpine` | `/var/lib/new-api-redis` (AOF) |
| fcgiwrap | unix socket | — | `fcgiwrap.socket` | — |
| git-mirror runner | (timer) | — | `git-mirror@%i.service` | `/var/lib/git-mirrors/<repo>.git` + `/var/lib/dist/<repo>/` |
| Xray | eth0 | 8443/tcp | xray.service | （现状不变） |
| 3x-ui | wg0 | 2053 | xui.service | （现状不变） |

### 1.2 IP 编号

```
WireGuard subnet : 10.8.0.0/24
  10.8.0.1/24    : Server A (hub)
  10.8.0.2/24    : Server B (private services)
  10.8.0.10-19   : 白名单 VPS (手工分配)
  10.8.0.100+    : 团队成员客户端
```

### 1.3 系统用户清单（B 上必须 useradd）

| 用户 | UID | shell | home | 用途 |
|---|---|---|---|---|
| `git-mirror` | autoassign (-r) | `/usr/sbin/nologin` | `/var/lib/git-mirrors` | 跑 git-mirror@.service |
| `verdaccio` (容器内) | 10001 | — | — | docker --user 10001:65533 |
| `bifrost-readonly` | autoassign (-r) | `/usr/lib/openssh/sftp-server` (no shell) | `/var/lib/bifrost-readonly` | bifrost-api SSH 拉日志 forced-command 专用 |

---

## 2. nftables 规则规范（v2：单 table、policy drop）

### 2.1 Server B `/etc/nftables.d/bifrost-distribution.nft`（统一到 `inet filter` 主 table）

```nft
#!/usr/sbin/nft -f

# 该文件由 security.sh + enable_distribution 合作生成。
# 它将分发服务规则注入主 inet filter 表，不另建 table。

table inet filter {

    set wg_clients_v4 {
        type ipv4_addr
        flags interval
        elements = { 10.8.0.0/24 }
    }

    set ssh_pubnet_allow_v4 {
        type ipv4_addr
        flags interval
        # bootstrap 时由 server-b.sh 注入：
        #   nft add element inet filter ssh_pubnet_allow_v4 { $(curl -s ifconfig.io)/32 }
        # 部署完成后由运维补 team IPs。
    }

    chain input {
        type filter hook input priority 0; policy drop;

        ct state established,related accept
        iif "lo" accept
        ip protocol icmp accept
        meta l4proto ipv6-icmp accept

        # WG 公网握手
        udp dport 51820 accept

        # SSH 双通道（任一即可）
        iifname "wg0" tcp dport 22 accept
        ip saddr @ssh_pubnet_allow_v4 tcp dport 22 accept

        # 分发服务：仅 wg0
        iifname "wg0" tcp dport { 3000, 4873, 8081, 8082 } accept

        # 同端口走公网 = 显式 drop（防 DOCKER chain 漏）
        iifname != "wg0" tcp dport { 3000, 4873, 8081, 8082 } drop
    }
}

# Docker daemon 的 DOCKER-USER 链不归 nftables 主表管，下面规则补齐
# （server-b.sh 在 docker 安装完成后写入 /etc/docker/daemon-overrides.sh）
```

### 2.2 关闭 docker bypass：DOCKER-USER 链规则

server-b.sh 执行：

```bash
iptables -I DOCKER-USER -i eth0 -p tcp --dport 3000 -j DROP
iptables -I DOCKER-USER -i eth0 -p tcp --dport 4873 -j DROP
iptables -I DOCKER-USER -i eth0 -p tcp --dport 8081 -j DROP
iptables -I DOCKER-USER -i eth0 -p tcp --dport 8082 -j DROP
# 持久化：netfilter-persistent save 或 写入 /etc/iptables/rules.v4
```

> **C1 fix**：删除原"distribution 单独 table、跨表 jump"设计，所有规则注入主 `inet filter`。
> **M9 fix**：补 DOCKER-USER 公网阻断，防 docker-proxy 通过 PREROUTING 漏出。
> **M17 fix**：bootstrap IP 自动注入 `ssh_pubnet_allow_v4`，避免锁死。

### 2.3 Server A nftables（增量）

A 上 nftables 仅需保证：

- 80/443 公网 accept（已有）
- 22 公网仅团队 IP allow（已有）
- wg0 接口出站到 B 的 3000/4873/8081/8082（默认 accept）

---

## 3. Caddy 配置规范

### 3.1 版本前置

- **Caddy ≥ 2.7.0**（snippet 位置参数 `{args[0]}` 稳定）。
- 在 server-a.sh / server-b.sh 部署 Caddy 处加版本检查：`caddy version | grep -E "v2\.[7-9]|v2\.[0-9]{2,}"`。

### 3.2 Server A 模板片段（追加到 `configs/caddy/Caddyfile-a.tpl`）

```caddy
# --- mirrored to Server B over wg tunnel ---
(server_b_proxy) {
    reverse_proxy {args[0]} {
        header_up Host {host}
        header_up X-Forwarded-Proto https
        header_up X-Real-IP {client_ip}
        health_uri /-/ping
        health_interval 10s
        health_timeout 2s
        lb_try_duration 2s
        fail_duration 30s
    }
}

api.{{DOMAIN}} {
    tls {{TLS_CERT_FILE}} {{TLS_KEY_FILE}}
    encode gzip
    import server_b_proxy http://10.8.0.2:3000
}

npm.{{DOMAIN}} {
    tls {{TLS_CERT_FILE}} {{TLS_KEY_FILE}}
    encode gzip
    handle {
        request_body {
            max_size 100MB
        }
        import server_b_proxy http://10.8.0.2:4873
    }
}

files.{{DOMAIN}} {
    tls {{TLS_CERT_FILE}} {{TLS_KEY_FILE}}
    encode gzip
    @git path /git/*
    handle @git {
        import server_b_proxy http://10.8.0.2:8082
    }
    handle {
        import server_b_proxy http://10.8.0.2:8081
    }
}
```

> **M5 fix**：`request_body` 放到 `handle {}` 内合法。
> **M6 fix**：明确 Caddy ≥ 2.7。
> **N1 fix**：files/git 也复用 `server_b_proxy` snippet。

### 3.3 Server B `/etc/caddy/Caddyfile`（git smart HTTP 完整环境变量）

```caddy
{
    admin off
    auto_https off
    servers {
        protocols h1 h2
    }
}

# files (静态分发)
10.8.0.2:8081 {
    root * /var/lib/dist
    file_server browse
    encode gzip
    log {
        output file /var/log/caddy/files.log {
            roll_size 50mb
            roll_keep 7
        }
    }
}

# git smart HTTP — 只读 mirror（明确禁 push）
10.8.0.2:8082 {
    # 阻止任何 receive-pack（push）
    @receive_pack {
        method POST
        path */git-receive-pack
    }
    handle @receive_pack {
        respond "git push disabled on mirror" 403
    }

    handle_path /git/* {
        reverse_proxy unix//run/fcgiwrap.socket {
            transport fastcgi {
                env GIT_HTTP_EXPORT_ALL true
                env GIT_PROJECT_ROOT /var/lib/git-mirrors
                env PATH_INFO {http.request.uri.path}
                env SCRIPT_NAME ""
                env SCRIPT_FILENAME /usr/lib/git-core/git-http-backend
                env QUERY_STRING {http.request.uri.query}
                env CONTENT_TYPE {http.request.header.Content-Type}
                env CONTENT_LENGTH {http.request.header.Content-Length}
                env REMOTE_ADDR {client_ip}
            }
        }
    }
}
```

> **C4 fix**：`@receive_pack` 显式 403。
> **M8 fix**：补 QUERY_STRING / SCRIPT_NAME / CONTENT_TYPE / CONTENT_LENGTH。
> **M7 fix**：systemd drop-in 见 §3.4。

### 3.4 Server B Caddy systemd drop-in

`/etc/systemd/system/caddy.service.d/wg-after.conf`:

```ini
[Unit]
Requires=wg-quick@wg0.service
After=wg-quick@wg0.service
```

---

## 4. Verdaccio 部署规范

### 4.1 `/etc/systemd/system/verdaccio.service`

```ini
[Unit]
Description=Verdaccio private npm registry
Requires=docker.service wg-quick@wg0.service
After=docker.service wg-quick@wg0.service

[Service]
Type=simple
WorkingDirectory=/var/lib/verdaccio
ExecStartPre=-/usr/bin/docker rm -f verdaccio
ExecStart=/usr/bin/docker run --name verdaccio \
    -p 10.8.0.2:4873:4873 \
    -e VERDACCIO_PUBLIC_URL=https://npm.uuhfn.cloud \
    -v /var/lib/verdaccio/storage:/verdaccio/storage \
    -v /var/lib/verdaccio/config:/verdaccio/conf \
    --user 10001:65533 \
    verdaccio/verdaccio:6.7.1
ExecStop=/usr/bin/docker stop verdaccio
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
```

> **C2 fix**：`Requires=wg-quick@wg0` + `After=`，wg 没起则 verdaccio 不起。
> **M1 fix**：去 `--rm`，依赖 ExecStartPre 清理；`Restart=on-failure`。

### 4.2 `/var/lib/verdaccio/config/config.yaml`（v2 关键节选）

```yaml
storage: /verdaccio/storage
url_prefix: /
listen: 0.0.0.0:4873   # 容器内 bind，docker 端口映射限定到 wg0:4873
auth:
  htpasswd:
    file: /verdaccio/storage/htpasswd
    max_users: -1
uplinks:
  npmjs:
    url: https://registry.npmjs.org/
    timeout: 30s
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
server:
  keepAliveTimeout: 60
log:
  type: stdout
  format: pretty-timestamped
  level: warn
```

### 4.3 htpasswd / bootstrap 密码（C3 + M2 + M3 + M4 修复）

```bash
init_verdaccio_htpasswd() {
    local htpasswd_path=/var/lib/verdaccio/storage/htpasswd
    local owner_uid=10001
    local owner_gid=65533

    # M2 幂等：仅首次创建
    if [ -f "$htpasswd_path" ]; then
        return 0
    fi

    # M4 修：把生成结果赋值
    local bootstrap_pwd
    bootstrap_pwd=$(openssl rand -hex 16)

    # M3 修：用 docker exec 让容器内 UID 写文件，所有权一致
    # 等 verdaccio 起来后再注入
    docker exec verdaccio htpasswd -cBb /verdaccio/storage/htpasswd team "$bootstrap_pwd"

    # C3 修：密码只 stdout 一次性显示 + 落盘 0400 root
    local pwd_file=/root/.verdaccio-bootstrap-pwd.txt
    umask 0277
    printf '%s\n' "$bootstrap_pwd" > "$pwd_file"
    chmod 0400 "$pwd_file"
    chown root:root "$pwd_file"

    echo "===================="
    echo "Verdaccio bootstrap account:"
    echo "  username: team"
    echo "  password: $bootstrap_pwd"
    echo "  (also saved to $pwd_file, 0400 root)"
    echo "===================="

    # deploy_state 只存"已设置"标志
    _save_deploy_state "VERDACCIO_HTPASSWD_INITIALIZED" "1"
    _save_deploy_state "VERDACCIO_HTPASSWD_FILE" "$htpasswd_path"
    # **不存密码本身**
}
```

`server-b.sh --rotate-bootstrap-pwd` 走独立路径：删除 htpasswd 后调本函数。

---

## 5. NewAPI 部署规范（B 上绿启）

> 依据 `research/04-newapi-postgres.md`：镜像锁 `calciumion/new-api:v1.0.0-rc.6`，DSN 单变量按前缀路由，PG 15，`sslmode=disable` 必须显式，调低 `SQL_MAX_OPEN_CONNS`。

### 5.1 `/opt/new-api/docker-compose.yml`

```yaml
services:
  new-api:
    image: calciumion/new-api:v1.0.0-rc.6
    container_name: new-api
    restart: always
    ports:
      - "10.8.0.2:3000:3000"
    environment:
      SQL_DSN: "postgres://newapi:${BIFROST_NEW_API_POSTGRES_PASSWORD}@postgres:5432/newapi?sslmode=disable"
      REDIS_CONN_STRING: "redis://redis:6379"
      SQL_MAX_OPEN_CONNS: "50"
      SQL_MAX_IDLE_CONNS: "10"
      SESSION_SECRET: "${SESSION_SECRET}"
      TZ: "Asia/Shanghai"
    volumes:
      - /var/lib/new-api/data:/data
    depends_on:
      postgres:
        condition: service_healthy
      redis:
        condition: service_started

  postgres:
    image: postgres:15
    container_name: new-api-pg
    restart: always
    environment:
      POSTGRES_USER: newapi
      POSTGRES_PASSWORD: ${BIFROST_NEW_API_POSTGRES_PASSWORD}
      POSTGRES_DB: newapi
    volumes:
      - /var/lib/new-api-pg:/var/lib/postgresql/data
      - ./pg-init.sh:/docker-entrypoint-initdb.d/00-init.sh:ro
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U newapi -d newapi -h 127.0.0.1"]
      interval: 5s
      timeout: 3s
      retries: 10
      start_period: 10s

  redis:
    image: redis:7-alpine
    container_name: new-api-redis
    restart: always
    command: ["redis-server", "--appendonly", "yes"]
    volumes:
      - /var/lib/new-api-redis:/data
```

> **M11 fix**：`condition: service_healthy`。
> **M10 fix**：SQL_DSN 单变量 + 显式 sslmode=disable + 调低连接数。
> **N2 fix**：Redis AOF 持久化 + 独立 volume。

### 5.2 `/opt/new-api/pg-init.sh`

```bash
#!/bin/bash
set -e
# PG 15 默认收回 public schema 权限，提前 GRANT
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
    GRANT ALL ON SCHEMA public TO "$POSTGRES_USER";
EOSQL
```

### 5.3 PG 密码状态机（M12 修）

```
1. enable_distribution 启动时读 _get_deploy_state BIFROST_NEW_API_POSTGRES_PASSWORD
   - 如未设：openssl rand -hex 32 → 写 state
2. 检测 /var/lib/new-api-pg/PG_VERSION 是否存在
   - 不存在：首次 init，密码即上一步生成的
   - 存在但 state 缺失：fail 并要求人工运维
   - 存在 + state 有 + docker exec pg_isready 失败 3 次：fail 并要求 `--force-reset-pg`
3. 启动 compose
```

### 5.4 SESSION_SECRET

```
_get_deploy_state SESSION_SECRET || _save_deploy_state SESSION_SECRET "$(openssl rand -hex 32)"
```

---

## 6. git mirror 系统服务规范

### 6.1 `/etc/systemd/system/git-mirror@.service`

```ini
[Unit]
Description=Mirror upstream git repo: %i
Requires=network-online.target
After=network-online.target

[Service]
Type=oneshot
User=git-mirror
Group=git-mirror
WorkingDirectory=/var/lib/git-mirrors
ExecStart=/usr/local/bin/git-mirror-sync.sh %i
StandardOutput=append:/var/log/git-mirror/%i.log
StandardError=append:/var/log/git-mirror/%i.log
```

### 6.2 `/etc/systemd/system/git-mirror@.timer`

```ini
[Unit]
Description=Daily mirror trigger for %i

[Timer]
OnCalendar=*-*-* 02:00:00
RandomizedDelaySec=120
Persistent=true
Unit=git-mirror@%i.service

[Install]
WantedBy=timers.target
```

### 6.3 `/usr/local/bin/git-mirror-sync.sh`（v2 修 M13 + M14 + C4）

```bash
#!/usr/bin/env bash
set -euo pipefail

REPO_SLUG="$1"
case "$REPO_SLUG" in
    claude-for-legal-zh)
        UPSTREAM="https://github.com/CSlawyer1985/claude-for-legal-ZH.git"
        ;;
    *)
        echo "Unknown repo slug: $REPO_SLUG" >&2
        exit 2
        ;;
esac

BARE="/var/lib/git-mirrors/${REPO_SLUG}.git"
TREE="/var/lib/dist-tree/${REPO_SLUG}"          # M14: tree 不在 dist 下
RELEASES="/var/lib/dist/${REPO_SLUG}/releases"  # releases 在 dist 下供 Caddy 服务

mkdir -p "$BARE" "$TREE" "$RELEASES"

if [ ! -d "$BARE/refs" ]; then
    git clone --mirror "$UPSTREAM" "$BARE"
fi

# M13: 不假设主分支叫 main
cd "$BARE"
DEFAULT_BRANCH=$(git symbolic-ref --short HEAD 2>/dev/null || echo "main")

HEAD_BEFORE=$(git rev-parse "$DEFAULT_BRANCH" 2>/dev/null || echo none)
git remote update --prune
HEAD_AFTER=$(git rev-parse "$DEFAULT_BRANCH")

git --bare update-server-info

[ "$HEAD_BEFORE" = "$HEAD_AFTER" ] && exit 0

# 工作树同步
if [ ! -d "$TREE/.git" ]; then
    git clone "$BARE" "$TREE"
fi
cd "$TREE"
git fetch origin
git reset --hard "origin/$DEFAULT_BRANCH"
git clean -fdx   # 现在安全：releases 不在此目录下

STAMP=$(date +%Y%m%d)
TAR="${RELEASES}/${REPO_SLUG}-${STAMP}.tar.gz"
git archive --format=tar.gz --prefix="${REPO_SLUG}/" -o "$TAR" HEAD
cp -f "$TAR" "${RELEASES}/latest.tar.gz"

find "$RELEASES" -maxdepth 1 -name "${REPO_SLUG}-*.tar.gz" -mtime +14 -delete

# 同步 bare 镜像到 dist 暴露目录（供 Caddy /git/* 访问）
rsync -a --delete "$BARE/" "/var/lib/git-mirrors/${REPO_SLUG}.git/"
```

> **M15 fix**：`User=git-mirror` 在 enable_distribution step 3 `useradd -r -s /usr/sbin/nologin -d /var/lib/git-mirrors git-mirror` 创建。
> **M13 fix**：`git symbolic-ref --short HEAD`。
> **M14 fix**：tree 移到 `/var/lib/dist-tree/`，releases 单独 `/var/lib/dist/<repo>/releases/`，git clean 不再误删。
> **C4 fix**：Caddy §3.3 阻断 receive-pack。

---

## 7. bifrost-api 新增路由规范（C5 + M16 修）

### 7.1 SSH 安全模型

bifrost-api 跑在 A 上，需通过 wg 访问 B 拉日志。**禁止用 A 上 root 的 SSH 私钥**。改为：

1. B 上 `useradd -r -m -d /var/lib/bifrost-readonly bifrost-readonly`
2. `bifrost-readonly` shell = `/usr/sbin/nologin`，但通过 `~/.ssh/authorized_keys` 的 `command=` 强制路由：

```
command="/usr/local/bin/bifrost-readonly-router.sh ${SSH_ORIGINAL_COMMAND}",no-port-forwarding,no-X11-forwarding,no-agent-forwarding,no-pty ssh-ed25519 AAAA...
```

3. `/usr/local/bin/bifrost-readonly-router.sh` 白名单允许的命令：

```bash
#!/usr/bin/env bash
set -euo pipefail
case "$1" in
    "logs:verdaccio")  exec docker logs --tail 200 verdaccio ;;
    "logs:new-api")    exec docker logs --tail 200 new-api ;;
    "logs:git-mirror") exec journalctl -u "git-mirror@${2:-claude-for-legal-zh}" --no-pager -n 200 ;;  # M16: 无 --user
    "disk:report")     exec du -sh /var/lib/verdaccio /var/lib/new-api-pg /var/lib/dist 2>/dev/null ;;
    "wg:age")          exec wg show wg0 latest-handshakes ;;
    *) echo "forbidden" >&2 ; exit 2 ;;
esac
```

4. A 上 SSH 私钥放 `/etc/bifrost-api/ssh/bifrost-readonly.ed25519`（0400 root:bifrost-api），bifrost-api 进程以 `bifrost-api` 系统用户运行，只这个用户能读。

5. **轮换 SOP**：每 90 天 `ssh-keygen -t ed25519 -f bifrost-readonly.ed25519 -N "" -C "rotated $(date +%F)"`，新公钥推 B 上 authorized_keys，旧公钥删除。

> **C5 fix**：专用低权账户 + forced-command 白名单 + 私钥独占文件权限 + 轮换 SOP。

### 7.2 接口契约

```python
GET /mirrors/status
→ 200
{
  "verdaccio": {"up": true, "url": "https://npm.uuhfn.cloud/", "version": "6.7.1"},
  "git_mirror_claude_for_legal_zh": {"last_synced_at": "2026-05-19T02:00:18+08:00", "head_sha": "..."},
  "newapi": {"up": true, "version": "v1.0.0-rc.6"},
  "wg_link": {"peer_b_handshake_age_sec": 12}
}

GET /mirrors/logs?service={verdaccio|new-api|git-mirror}&tail=200
→ 200 text/plain
<stdout of bifrost-readonly-router.sh logs:{service}>

GET /mirrors/disk
→ 200
{
  "verdaccio_storage_mb": 1238,
  "newapi_pg_mb": 73,
  "git_mirrors_mb": 51
}
```

### 7.3 实现要点

- 状态类：bifrost-api 直接 HTTP GET `http://10.8.0.2:4873/-/ping` 等。
- 日志类：用 `paramiko.SSHClient` 调 `bifrost-readonly@10.8.0.2 "logs:verdaccio"`。
- `wg_link` 探活：`wg show wg0 latest-handshakes` 在 A 上 root 跑（不跨机）。
- 鉴权：复用 bifrost-api 现有 `dependencies.py:require_admin`。
- 新增配置 key：`BIFROST_SERVER_B_WG_IP=10.8.0.2`、`BIFROST_READONLY_SSH_KEY=/etc/bifrost-api/ssh/bifrost-readonly.ed25519`、`BIFROST_READONLY_USER=bifrost-readonly`。

---

## 8. server-b.sh 改动规范

### 8.1 新增子命令

```bash
bash scripts/server-b.sh --enable-distribution
bash scripts/server-b.sh --disable-distribution
bash scripts/server-b.sh --rotate-bootstrap-pwd
```

### 8.2 `enable_distribution()` 函数

```bash
enable_distribution() {
    _step "1/11 verify wg0 up"
    _require_wg0

    _step "2/11 bootstrap ssh_pubnet_allow_v4 (M17 防锁死)"
    local my_pubip
    my_pubip=$(curl -sf --max-time 5 https://ifconfig.io || true)
    if [ -n "$my_pubip" ]; then
        nft add element inet filter ssh_pubnet_allow_v4 "{ ${my_pubip}/32 }" 2>/dev/null || true
        echo "[bootstrap] added $my_pubip/32 to ssh_pubnet_allow_v4"
    else
        echo "[bootstrap] WARN: could not detect public IP; ensure ssh_pubnet_allow_v4 has at least one entry before deploy"
    fi

    _step "3/11 install docker + ensure git-mirror user"
    _ensure_docker
    id git-mirror &>/dev/null || useradd -r -s /usr/sbin/nologin -d /var/lib/git-mirrors -m git-mirror
    id bifrost-readonly &>/dev/null || useradd -r -m -d /var/lib/bifrost-readonly -s /bin/bash bifrost-readonly

    _step "4/11 prepare directories (M18 显式多次调用)"
    _mkdir_p_owned 10001:65533 /var/lib/verdaccio/storage
    _mkdir_p_owned 10001:65533 /var/lib/verdaccio/config
    _mkdir_p_owned 999:999     /var/lib/new-api-pg
    install -d -m 0755 -o git-mirror -g git-mirror /var/lib/git-mirrors /var/log/git-mirror /var/lib/dist-tree
    install -d -m 0755 -o root      -g root      /var/lib/dist

    _step "5/11 render verdaccio config + systemd unit"
    _render_template configs/verdaccio/config.yaml.tpl /var/lib/verdaccio/config/config.yaml
    install -m 0644 configs/systemd/verdaccio.service /etc/systemd/system/
    systemctl daemon-reload
    systemctl enable --now verdaccio.service
    _wait_for_tcp 10.8.0.2 4873 60

    _step "6/11 init verdaccio htpasswd (idempotent)"
    init_verdaccio_htpasswd   # 见 §4.3

    _step "7/11 render NewAPI compose + ensure secrets"
    _ensure_state_kv BIFROST_NEW_API_POSTGRES_PASSWORD "$(openssl rand -hex 32)"
    _ensure_state_kv SESSION_SECRET "$(openssl rand -hex 32)"
    install -d -m 0755 /opt/new-api
    _render_template configs/new-api/docker-compose.yml.tpl /opt/new-api/docker-compose.yml
    install -m 0755 configs/new-api/pg-init.sh /opt/new-api/pg-init.sh
    (cd /opt/new-api && docker compose up -d)

    _step "8/11 install fcgiwrap + git-mirror timers"
    _ensure_pkg fcgiwrap git
    systemctl enable --now fcgiwrap.socket
    install -m 0644 configs/systemd/git-mirror@.service /etc/systemd/system/
    install -m 0644 configs/systemd/git-mirror@.timer   /etc/systemd/system/
    install -m 0755 scripts/git-mirror-sync.sh /usr/local/bin/git-mirror-sync.sh
    systemctl daemon-reload
    systemctl enable --now git-mirror@claude-for-legal-zh.timer
    systemctl start git-mirror@claude-for-legal-zh.service

    _step "9/11 render Caddyfile + start Caddy"
    install -d -m 0755 /etc/caddy/Caddyfile.d
    _render_template configs/caddy/Caddyfile-b-distribution.tpl /etc/caddy/Caddyfile.d/distribution.caddy
    install -d -m 0755 /etc/systemd/system/caddy.service.d
    install -m 0644 configs/systemd/caddy-wg-after.conf /etc/systemd/system/caddy.service.d/wg-after.conf
    systemctl daemon-reload
    systemctl reload caddy || systemctl restart caddy

    _step "10/11 install nftables + DOCKER-USER rules"
    install -d -m 0755 /etc/nftables.d
    install -m 0644 configs/nftables/bifrost-distribution.nft.tpl /etc/nftables.d/bifrost-distribution.nft
    nft -f /etc/nftables.d/bifrost-distribution.nft
    for port in 3000 4873 8081 8082; do
        iptables -C DOCKER-USER -i eth0 -p tcp --dport "$port" -j DROP 2>/dev/null \
            || iptables -I DOCKER-USER -i eth0 -p tcp --dport "$port" -j DROP
    done
    netfilter-persistent save || true

    _step "11/11 verify"
    _verify_distribution_endpoints
    _save_deploy_state DISTRIBUTION_ENABLED 1
}
```

### 8.3 幂等性保证（M19 增强）

- `install -m -o -g` 是幂等 atomic 写。
- `_render_template` 比对源/目标 sha256，相同跳过。
- `systemctl enable --now` 天然幂等。
- `docker compose up -d` 天然幂等。
- `_ensure_state_kv` 仅在 key 缺失时生成新值，已存在则保留。
- `nft -f` 重复加载同文件无副作用（自动 flush 同 table）。
- `iptables -C ... || iptables -I` 防重复插入。

### 8.4 部分失败恢复（M19 / AC-11）

任何 step 失败 → 退出 1 → 修复后重跑 enable_distribution → 跳过已完成 step。

`_step` 函数在 `/var/lib/bifrost/.step-state` 落盘 step N 完成标记；重跑时跳过已完成 step。失败 step 第二次执行视为新尝试，不绑定上次状态。

---

## 9. WG key 轮换 SOP（N4 修）

### 9.1 触发条件

- A 重装 / 私钥泄漏 / 90 天计划轮换

### 9.2 步骤（在 A 上执行）

```bash
# 1. 生成新 keypair
wg genkey | tee /etc/wireguard/wg0-new.key | wg pubkey > /etc/wireguard/wg0-new.pub

# 2. 推送新公钥到 B（用现役 wg key 还能跑的最后窗口）
NEW_PUB=$(cat /etc/wireguard/wg0-new.pub)
ssh root@10.8.0.2 "wg set wg0 peer $(cat /etc/wireguard/wg0.pub) remove ;
                   wg set wg0 peer $NEW_PUB allowed-ips 10.8.0.1/32"

# 3. 在 A 上切换私钥
wg set wg0 private-key /etc/wireguard/wg0-new.key
mv /etc/wireguard/wg0-new.key /etc/wireguard/wg0.key
mv /etc/wireguard/wg0-new.pub /etc/wireguard/wg0.pub
wg-quick down wg0 && wg-quick up wg0

# 4. 验证
wg show wg0 latest-handshakes   # 应 < 10s
ssh root@10.8.0.2 'date'         # 通了即成功
```

未来可加 `scripts/rotate-wg-key.sh` 自动化。本任务**不写脚本**，只入文档。

---

## 10. PR 拆分计划 v2

> 每个 PR ≤ 800 LOC、独立部署、独立测试、独立回滚。

| PR | 名称 | 内容 | 依赖 |
|---|---|---|---|
| PR-1 | 基础设施模板 | configs/{systemd,verdaccio,new-api,caddy,nftables}/*.tpl + scripts/git-mirror-sync.sh + scripts/bifrost-readonly-router.sh | 无 |
| PR-2 | server-b.sh 集成 | enable_distribution / disable_distribution / rotate-bootstrap-pwd | PR-1 |
| PR-3 | Server A 反代 + Caddyfile 更新 | Caddyfile-a.tpl 加 site，install_new_api 移到 legacy 子命令 | **05-19-server-a-hardening-v2 PR-3 合 main** |
| PR-4 | bifrost-api `/mirrors/*` dashboard | mirrors.py + paramiko 接入 + SSH 安全模型 | PR-1 ~ PR-3，**可独立交付，N3 标注** |
| PR-5 | diagnostics + 文档 | diagnostics.sh distribution check + USAGE/SECURITY 更新 + 团队公告 | PR-2/PR-3 |
| PR-6 | Windows VPS 退役 SOP | scripts/legacy-vps-final-snapshot.ps1 + 公告 | PR-5 |
| PR-7 | restic 备份 | systemd unit + 告警钩子 | PR-2 |
| PR-8 | E2E 演练 | scripts/e2e-distribution-rehearsal.sh + cutover/rollback runbook | 全部 |

---

## 11. 验收测试矩阵 v2

| ID | 场景 | 期望 | 工具 |
|---|---|---|---|
| AC-01 | 公网 portscan B | 仅 22/51820 开放 | nmap |
| AC-02 | 公网 curl npm.uuhfn.cloud | 200 + Verdaccio header | curl |
| AC-03 | 公网 npm install @anthropic-ai/claude-code | 成功 + tarball URL = https://npm.uuhfn.cloud/... | npm |
| AC-04 | git clone https://files.uuhfn.cloud/git/claude-for-legal-ZH.git | 成功，12 子目录 | git |
| AC-05 | curl https://files.uuhfn.cloud/team-config/.claude.json.template | 200 + 内容匹配 | curl |
| AC-06 | curl https://api.uuhfn.cloud/api/status | 200 + NewAPI status JSON | curl |
| AC-07 | wg-quick down wg0 on A | 上述全部 502 + bifrost-api dashboard 标红 | manual |
| AC-08 | restic snapshots on A | 至少一条 B 来源快照 | restic |
| AC-09 | 二次执行 `--enable-distribution` | 退出码 0 + 秒级完成 | bash time |
| AC-10 | `diagnostics.sh --check distribution` | 全 PASS | bash |
| **AC-11** | **部分失败重入**：step 6 后 kill server-b.sh，再次跑 `--enable-distribution` 应成功；新增 step 应跳过已完成项 | 退出 0 + 跳过日志可见 | bash |
| **AC-12** | **WG 抖动恢复**：`wg-quick down wg0 && sleep 5 && wg-quick up wg0` ≤45s 内全链路 curl 200 | 测试脚本计时 | bash |
| **AC-13** | **docker 镜像源 fallback**：`iptables -I OUTPUT -d registry-1.docker.io -j DROP` 后重跑 `--enable-distribution` 应自动切国内镜像源并完成 | 完成 + 日志含 fallback 标记 | bash |
| **AC-14** | **git push 被拒**：`git push https://files.uuhfn.cloud/git/claude-for-legal-ZH.git` 应返回 403 | git push | bash |
| **AC-15** | **htpasswd 幂等**：第二次跑 `--enable-distribution` 后 htpasswd 文件 mtime 不变 | stat | bash |
| **AC-16** | **bifrost-readonly SSH forced-command**：`ssh bifrost-readonly@10.8.0.2 'whoami'` 应失败（白名单外） | ssh | bash |

---

## 12. 风险登记簿 v2

| Risk | Probability | Impact | Mitigation |
|---|---|---|---|
| 与 05-19-server-a-hardening-v2 PR-3 合并冲突 | High | High | 等 PR-3 合 main 后开 PR-3 of 本任务 |
| 团队成员 cc-switch 旧 key 失效集中支持 | High | Medium | 提前 3 天发指引 + 录视频 |
| docker/postgres 国内安装失败 | Medium | High | AC-13 验证 fallback 路径 |
| Verdaccio storage 损坏 | Low | High | restic 推 A，恢复 SOP 入 SECURITY.md |
| WG 抖动放大 502 | Medium | Medium | Caddy `lb_try_duration 2s`，AC-12 |
| bootstrap 时机锁死自己 | Low | High | M17 自动 IP 注入 + 留控制台 break-glass |
| WG 私钥泄漏 | Low | Critical | §9 轮换 SOP |
| bifrost-api SSH 私钥泄漏 | Low | Critical | C5 forced-command + 90 天轮换 |
| Caddy <2.7 默认安装 | Medium | Low | 部署脚本版本检查 + 自动升级 |

---

## 13. 关联任务

| 任务 | 关系 |
|---|---|
| `05-19-server-a-hardening-v2` PR-3 | **前置**：等合 main 后开本任务 PR-3 |
| `05-19-server-a-hardening-v2` PR-1/PR-2 | 并行无冲突 |
| `05-18-newapi-uuhfn-cloud-package` | **覆盖**：外部 VPS NewAPI 配置包转 legacy |
| `05-06-cloud-security-availability-hardening` | 强化方向一致 |

---

## 14. GitNexus 影响分析

```bash
gitnexus_impact target=deploy_server_b direction=upstream
gitnexus_impact target=deploy_server_a direction=upstream
gitnexus_impact target=setup_caddy_a direction=upstream
gitnexus_impact target=install_new_api direction=upstream    # PR-3 删除主路径调用前必跑
gitnexus_context name=_save_deploy_state
gitnexus_detect_changes scope=staged   # PR commit 前
```

---

## 15. Done 标准（DoD）

- [ ] 所有 8 PR 合入 main
- [ ] AC-01 ~ AC-16 全 PASS
- [ ] `tests/test-in-docker.sh distribution` 在 CI 通过
- [ ] Windows VPS 下线（T+8）
- [ ] `docs/USAGE.md` + `docs/SECURITY.md` 同步
- [ ] 团队成员重建账号完成率 100%
- [ ] B 上 restic 至少有 7 天历史快照
- [ ] PRD + spec v2 + spec-review + 4 篇 research 归档至 `prompts/0519-1/` 与 `.trellis/tasks/05-19-server-b-private-distribution/`

---

## 16. 附录 — 关键命令

```bash
# 部署
bash scripts/server-b.sh --enable-distribution

# 健康检查
bash scripts/diagnostics.sh --check distribution

# 手动触发一次镜像同步
systemctl start git-mirror@claude-for-legal-zh.service

# 旋转 Verdaccio 初始密码
bash scripts/server-b.sh --rotate-bootstrap-pwd

# 强制重启
systemctl restart verdaccio
docker compose -f /opt/new-api/docker-compose.yml restart

# 从 A 备份恢复 B
restic -r sftp:bifrost-a:/srv/restic restore latest --target /var/lib/verdaccio

# 关闭整个分发栈（不删数据）
bash scripts/server-b.sh --disable-distribution
```

---

## v1 → v2 变更摘要

| Δ | 影响 § | Findings closed |
|---|---|---|
| nftables 改单 table policy drop | §2 | C1, M17 |
| docker -p 启动顺序 Requires=wg-quick | §4.1, §3.4 | C2, M7 |
| 明文密码改 stdout + 0400 文件 + 布尔 state | §4.3 | C3 |
| htpasswd 幂等 + docker exec 写文件 + 变量 bug 修 | §4.3 | M2, M3, M4 |
| git push 路径 403 + 完整 fastcgi env | §3.3 | C4, M8 |
| bifrost-api SSH forced-command + 专用账户 | §7.1 | C5 |
| docker --rm 去除 | §4.1 | M1 |
| Caddy 版本 ≥2.7 锁定 + request_body 位置 + snippet 复用 | §3.1-3.2 | M5, M6, N1 |
| NewAPI 镜像锁 v1.0.0-rc.6 + SQL_DSN 单变量 + sslmode + healthcheck + pg-init | §5 | M10, M11 |
| Redis AOF | §5.1 | N2 |
| PG 密码状态机 | §5.3 | M12 |
| git symbolic-ref HEAD + releases 移出 TREE + git-mirror useradd | §6.3, §8.2 | M13, M14, M15 |
| journalctl 去 --user | §7.1 | M16 |
| _mkdir_p_owned 单参数 | §8.2 | M18 |
| AC-11/12/13/14/15/16 新增 | §11 | M19, N5 |
| WG key 轮换 SOP | §9 | N4 |
| PR-4 标注"可独立交付" | §10 | N3 |
