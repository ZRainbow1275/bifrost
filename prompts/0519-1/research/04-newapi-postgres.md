# Research: calciumion/new-api Docker — PostgreSQL Support Matrix (M10)

- **Query**: 调研 `calciumion/new-api` 镜像对 PostgreSQL 的官方支持矩阵（最新 tag、DB 环境变量、PG 版本、坑、healthcheck）
- **Scope**: external（GitHub README、源码、Issues、Docker Hub、官方 docker-compose.yml）
- **Date**: 2026-05-19

> ⚠️ 仓库已迁移：原 `Calcium-Ion/new-api` → 现 `QuantumNous/new-api`（GitHub 自动 301 重定向）。Docker 镜像仍发布为 **`calciumion/new-api`**（小写驼峰），未变更。

---

## 1. 最新 Docker 镜像 Tag

来源：Docker Hub API `hub.docker.com/v2/repositories/calciumion/new-api/tags`

| Tag | 推送时间 | 架构 | 镜像大小 |
|---|---|---|---|
| `calciumion/new-api:v1.0.0-rc.6` | 2026-05-13 | multi-arch (amd64/arm64) | ~59 MB |
| `calciumion/new-api:v1.0.0-rc.6-amd64` | 2026-05-13 | amd64 | 59 MB |
| `calciumion/new-api:v1.0.0-rc.6-arm64` | 2026-05-13 | arm64 | 57 MB |
| `calciumion/new-api:v1.0.0-rc.5` | 2026-05-12 | multi-arch | 59 MB |
| `calciumion/new-api:v1.0.0-rc.4` | 2026-05-06 | multi-arch | 59 MB |
| `calciumion/new-api:latest` | 2026-05-13 | multi-arch | 59 MB |
| `calciumion/new-api:nightly` | rolling（每日） | multi-arch | — |

**推荐 pin 版本**：`calciumion/new-api:v1.0.0-rc.6`（避免 `latest`/`nightly` 漂移；该 rc.6 已包含 #4853 / #4857 / #4865 三个关键 PG 修复，详见第 4 节）。

GitHub Release 元数据：
- 最新 release `v1.0.0-rc.6`，发布于 2026-05-13T14:29:13Z（`published_at`）
- 不是 prerelease（`prerelease: false`）
- 项目仍处于 `1.0.0-rc.*` 阶段，尚无 GA 版本

---

## 2. 数据库环境变量（关键）

### 2.1 唯一开关：`SQL_DSN`

源码确认（`model/main.go` 函数 `chooseDB`）：**没有 `DB_TYPE` 或 `SQL_DRIVER` 这种独立开关**。new-api 通过 `SQL_DSN` 的**字符串前缀**自动判断数据库类型：

| DSN 前缀 / 值 | 触发的数据库 | 驱动 |
|---|---|---|
| `postgres://...` 或 `postgresql://...` | **PostgreSQL**（设置 `common.UsingPostgreSQL = true`）| `gorm.io/driver/postgres` (pgx v5) |
| `local` 或环境变量未设置 | **SQLite**（默认；写入 `./data/one-api.db`）| `glebarez/sqlite` |
| 其它（含 `user:pass@tcp(host:port)/db`）| **MySQL**（fallback 分支；自动追加 `?parseTime=true`）| `gorm.io/driver/mysql` |

代码片段（精简自 `model/main.go`）：

```go
func chooseDB(envName string, isLog bool) (*gorm.DB, error) {
    dsn := os.Getenv(envName)
    if dsn != "" {
        if strings.HasPrefix(dsn, "postgres://") || strings.HasPrefix(dsn, "postgresql://") {
            common.UsingPostgreSQL = true
            return gorm.Open(postgres.New(postgres.Config{
                DSN:                  dsn,
                PreferSimpleProtocol: true,
            }), &gorm.Config{PrepareStmt: true})
        }
        if strings.HasPrefix(dsn, "local") { /* SQLite */ }
        // MySQL fallback
        common.UsingMySQL = true
        return gorm.Open(mysql.Open(dsn), ...)
    }
    // 默认 SQLite
    return gorm.Open(sqlite.Open(common.SQLitePath), ...)
}
```

### 2.2 各数据库 DSN 范例（直接照搬即可）

```bash
# SQLite（默认，零配置；数据写入 -v 挂载的 /data 目录）
# 不设置 SQL_DSN 即可

# MySQL
SQL_DSN=root:123456@tcp(mysql:3306)/new-api

# PostgreSQL（推荐两种之一）
SQL_DSN=postgres://root:123456@postgres:5432/new-api
SQL_DSN=postgresql://newapi:strongpass@pg.internal:5432/newapi
```

### 2.3 连接池 & 辅助环境变量

| 环境变量 | 默认值 | 说明 |
|---|---|---|
| `SQL_DSN` | 空（→ SQLite）| 主数据库 DSN |
| `LOG_SQL_DSN` | 空（→ 与主库相同）| 日志库独立 DSN（可拆出热数据 / 冷日志）|
| `SQL_MAX_IDLE_CONNS` | `100` | 空闲连接数（PG 单连接昂贵，建议调到 10-20）|
| `SQL_MAX_OPEN_CONNS` | `1000` | 最大连接数（PG 服务端默认 `max_connections=100`，必须下调到 < server_max - 余量）|
| `SQL_MAX_LIFETIME` | `300`（秒；v1.0.0-rc.5 起；之前是 60）| 连接生命周期，rc.5 通过 #4857 改为 300 减少 TLS 握手开销 |
| `REDIS_CONN_STRING` | 空 | Redis 缓存（PG 大规模时强烈建议）|
| `SESSION_SECRET` | 空（rc.5 起会告警） | 多机部署必须；持久化 session |
| `CRYPTO_SECRET` | 空 | 启用 Redis 时必需 |

完整变量见官方 docs：https://docs.newapi.pro/en/docs/installation/config-maintenance/environment-variables

---

## 3. 实际可用的 PostgreSQL 版本

来源：官方 `docker-compose.yml`（main 分支）

- **官方推荐**：`postgres:15`（写死在官方 compose 文件 line 56）
- **兼容范围**：使用 `gorm.io/driver/postgres` + `jackc/pgx/v5` v5.9.0（依赖 PR #4294 升级），理论上 PG 12 / 13 / 14 / 15 / 16 / 17 均可
- **PG 必需扩展**：**无**。new-api 全部使用纯 SQL + GORM AutoMigrate，未声明任何 `CREATE EXTENSION`（如 `pgvector`、`pg_trgm` 等）。所有索引为 B-Tree / GIN 默认实现。
- **schema**：默认使用 `public` schema；用户必须有 `CREATE ON SCHEMA public` 权限（详见第 4.1 节）

**建议生产选型**：
- `postgres:16-alpine`（最新稳定 GA，小镜像，社区主力）
- `postgres:15`（与官方 compose 完全一致，最安全）
- ❌ 避免 `postgres:17-beta*`（new-api 未正式验证）

---

## 4. 已知与 PG 配合时的坑（必读）

### 4.1 `permission denied for schema public` (SQLSTATE 42501)

**触发**：从旧 `latest` 镜像滚动到新版本后，启动失败循环。
- **原因**：PostgreSQL 15+ 默认收回 `public` schema 的 `CREATE` 权限（不再隐式授予普通用户）。new-api 容器升级后需要执行 `ALTER TABLE` 触发 AutoMigrate，但建表/改表权限被拒。
- **来源**：[Issue #4178](https://github.com/QuantumNous/new-api/issues/4178)（官方维护者 `Calcium-Ion` 与 `feitianbubu` 给出修复方案）
- **修复**：登录 PG 执行：
  ```sql
  GRANT CREATE ON SCHEMA public TO <newapi_user>;
  GRANT USAGE ON SCHEMA public TO <newapi_user>;
  -- 或干脆：
  GRANT ALL ON SCHEMA public TO <newapi_user>;
  ```
- **预防**：用 `POSTGRES_USER=root` 作为 owner（官方 compose 写法）或在 init SQL 中预先 GRANT。

### 4.2 PG DSN 默认强制 `sslmode=require`

**v1.0.0-rc.5+（PR #4857）行为变化**：
- new-api 现在**自动**在 PG DSN 末尾追加 `sslmode=require`（仅当用户未显式指定）。
- **本地 docker-compose 内部网络**：必须显式追加 `?sslmode=disable`，否则容器互联会握手失败。
- **示例**：
  ```bash
  # docker-compose 内部网络（postgres 容器无 TLS）
  SQL_DSN=postgres://root:123456@postgres:5432/new-api?sslmode=disable

  # 云数据库 / VPC 跨主机
  SQL_DSN=postgres://user:pass@db.example.com:5432/newapi?sslmode=require
  ```

### 4.3 GORM AutoMigrate 反复 ALTER TABLE（已修复）

**v1.0.0-rc.5 之前**：每次启动对 `logs.request_id` 执行 `ALTER COLUMN ... TYPE varchar(64) USING ...`，触发 PG 全表重写。  
**来源**：[Issue #4054](https://github.com/QuantumNous/new-api/issues/4054) → [PR #4055](https://github.com/QuantumNous/new-api/pull/4055)（升级 `gorm.io/driver/postgres` 1.5.2 → 1.6.0，`gorm.io/gorm` 1.25.2 → 1.31.1）。  
**结论**：**必须用 ≥ `v1.0.0-rc.5` 的镜像**，否则大日志表每次重启都全表重写。

### 4.4 `ifnull()` 不兼容（已修复）

**v1.0.0-rc.4 之前**：Dashboard 统计 SQL 用 `IFNULL()`，PG 不支持，导致 Dashboard 接口 500。  
**来源**：[Issue #3422](https://github.com/QuantumNous/new-api/issues/3422) → PR #4853（`IFNULL` → `COALESCE`）。修复版本：`v1.0.0-rc.5+`。

### 4.5 `column reference "generation_ms" is ambiguous` (SQLSTATE 42702)（已修复）

**v1.0.0-rc.4 表现**：`perf_metrics` upsert 不限定列名，PG strict mode 报歧义。  
**来源**：[Issue #4683](https://github.com/QuantumNous/new-api/issues/4683) → [PR #4684](https://github.com/QuantumNous/new-api/pull/4684)。修复版本：`v1.0.0-rc.5+`。

### 4.6 `TRUNCATE TABLE` 在 PG 上需要外键级联权限（已修复）

**修复**：`model/ability.go` 在 PG 分支改用 `DELETE FROM`（与 SQLite 同），避免 PG TRUNCATE 不重置序列 + 外键级联的问题。来源：PR #4865，rc.6 包含。

### 4.7 连接池设置建议

- 默认 `SQL_MAX_OPEN_CONNS=1000` 对 PG 来说**远超** server 端默认 `max_connections=100`，必须手动下调。
- 多 worker（NODE_TYPE=slave）部署：每节点 50–100 即可，合计不超过 server 80%。
- `PreferSimpleProtocol: true`：源码已设置，避免 pgbouncer transaction mode 下的 prepared statement 问题（与 pgbouncer 兼容）。
- `PrepareStmt: true`：GORM 层预编译（与上面不冲突，是 GORM 缓存，不是 server-side）。

---

## 5. 标准 PostgreSQL Healthcheck（docker-compose `depends_on`）

new-api 自身的 healthcheck（已在官方 compose 中）：

```yaml
healthcheck:
  test: ["CMD-SHELL", "wget -q -O - http://localhost:3000/api/status | grep -o '\"success\":\\s*true' || exit 1"]
  interval: 30s
  timeout: 10s
  retries: 3
```

**PostgreSQL 容器的标准 healthcheck**（官方 compose 没写，建议补上）：

```yaml
postgres:
  image: postgres:15
  healthcheck:
    test: ["CMD-SHELL", "pg_isready -U $${POSTGRES_USER} -d $${POSTGRES_DB} -h 127.0.0.1"]
    interval: 5s
    timeout: 5s
    retries: 10
    start_period: 30s
```

配合 `depends_on` 的 long-form（必须用 v2 long-form 才能等 healthy）：

```yaml
new-api:
  depends_on:
    postgres:
      condition: service_healthy
    redis:
      condition: service_healthy
```

> 注：`docker-compose.yml` 顶部声明 `version: '3.4'` 即支持 long-form `depends_on.condition`，所以无需升级到 3.8。

---

## 6. 建议的 docker-compose.yml 环境变量配置块（可直接粘贴）

这是基于官方 compose + 全部 PG 修复 + 安全加固的 **生产就绪** 版本：

```yaml
# docker-compose.yml — Server B 私有分发：new-api + PostgreSQL 15 + Redis 7
version: '3.4'

services:
  new-api:
    image: calciumion/new-api:v1.0.0-rc.6   # pin 版本，避免 latest/nightly 漂移
    container_name: new-api
    restart: always
    command: --log-dir /app/logs
    ports:
      - "127.0.0.1:3000:3000"               # 仅 loopback，外部走 nginx/caddy
    volumes:
      - ./data:/data                        # SQLite 文件回落 + 资源
      - ./logs:/app/logs
    environment:
      # ── 数据库 ──────────────────────────────────────────────
      - SQL_DSN=postgres://newapi:${POSTGRES_PASSWORD}@postgres:5432/newapi?sslmode=disable
      # ⚠️ docker 内部网络必须 sslmode=disable，否则 rc.5+ 默认追加 sslmode=require 会握手失败
      - SQL_MAX_OPEN_CONNS=80               # PG 默认 max_connections=100，留余量
      - SQL_MAX_IDLE_CONNS=20
      - SQL_MAX_LIFETIME=300                # 与 rc.5+ 默认一致

      # ── 缓存 ──────────────────────────────────────────────
      - REDIS_CONN_STRING=redis://:${REDIS_PASSWORD}@redis:6379

      # ── 安全 ──────────────────────────────────────────────
      - SESSION_SECRET=${SESSION_SECRET}    # 多机部署必填，rc.5+ 缺失会告警
      - CRYPTO_SECRET=${CRYPTO_SECRET}      # Redis 启用时必填
      - CORS_ALLOW_ALL_ORIGINS=false        # 生产关闭（rc.5+ 新增）
      - WS_ALLOW_ALL_ORIGINS=false

      # ── 运行时 ────────────────────────────────────────────
      - TZ=Asia/Shanghai
      - ERROR_LOG_ENABLED=true
      - BATCH_UPDATE_ENABLED=true
      - NODE_NAME=newapi-master-1
      - RELAY_TIMEOUT=60                    # rc.5+ 默认 60，老版本需手动设
    depends_on:
      postgres:
        condition: service_healthy
      redis:
        condition: service_healthy
    networks: [new-api-net]
    healthcheck:
      test: ["CMD-SHELL", "wget -q -O - http://localhost:3000/api/status | grep -o '\"success\":\\s*true' || exit 1"]
      interval: 30s
      timeout: 10s
      retries: 3

  postgres:
    image: postgres:15-alpine               # 与官方 compose 推荐一致
    container_name: newapi-postgres
    restart: always
    environment:
      POSTGRES_USER: newapi
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
      POSTGRES_DB: newapi
      PGDATA: /var/lib/postgresql/data/pgdata
    volumes:
      - pg_data:/var/lib/postgresql/data
      # 可选：init SQL 解决 schema public 权限问题
      # - ./init/01-grants.sql:/docker-entrypoint-initdb.d/01-grants.sql:ro
    networks: [new-api-net]
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U $${POSTGRES_USER} -d $${POSTGRES_DB} -h 127.0.0.1"]
      interval: 5s
      timeout: 5s
      retries: 10
      start_period: 30s

  redis:
    image: redis:7-alpine
    container_name: newapi-redis
    restart: always
    command: ["redis-server", "--requirepass", "${REDIS_PASSWORD}", "--appendonly", "yes"]
    volumes:
      - redis_data:/data
    networks: [new-api-net]
    healthcheck:
      test: ["CMD", "redis-cli", "-a", "${REDIS_PASSWORD}", "ping"]
      interval: 5s
      timeout: 5s
      retries: 10

volumes:
  pg_data:
  redis_data:

networks:
  new-api-net:
    driver: bridge
```

配套 `.env` 模板：

```bash
# .env （chmod 600）
POSTGRES_PASSWORD=<openssl rand -hex 24>
REDIS_PASSWORD=<openssl rand -hex 24>
SESSION_SECRET=<openssl rand -hex 32>
CRYPTO_SECRET=<openssl rand -hex 32>
```

配套 `./init/01-grants.sql`（可选，提前授权避免 #4178）：

```sql
-- 在 newapi 数据库内执行（postgres 镜像首次启动会自动 source /docker-entrypoint-initdb.d/*.sql）
GRANT ALL ON SCHEMA public TO newapi;
GRANT ALL PRIVILEGES ON DATABASE newapi TO newapi;
```

---

## External References

| Link | 用途 |
|---|---|
| https://github.com/QuantumNous/new-api | 主仓库（已从 Calcium-Ion 迁移） |
| https://hub.docker.com/r/calciumion/new-api/tags | Docker tag 列表，确认 rc.6 是最新 |
| https://github.com/QuantumNous/new-api/blob/main/docker-compose.yml | 官方 compose 模板（postgres:15）|
| https://github.com/QuantumNous/new-api/blob/main/model/main.go | `chooseDB` 函数，DSN 前缀检测逻辑 |
| https://docs.newapi.pro/en/docs/installation/config-maintenance/environment-variables | 官方完整环境变量文档 |
| https://github.com/QuantumNous/new-api/issues/4178 | `permission denied for schema public` |
| https://github.com/QuantumNous/new-api/issues/4054 + PR #4055 | AutoMigrate 全表重写 |
| https://github.com/QuantumNous/new-api/pull/4857 | sslmode=require 默认行为 |
| https://github.com/QuantumNous/new-api/pull/4865 | TRUNCATE→DELETE for PG |
| https://github.com/QuantumNous/new-api/pull/4853 | IFNULL→COALESCE for PG |
| https://github.com/QuantumNous/new-api/issues/4683 + PR #4684 | `generation_ms` ambiguous fix |

---

## Caveats / Not Found

- **未官方声明的 PG 版本上限**：README/docs 没有"支持 PG 17"或"不支持 PG 13"的明确表述。官方 compose 只钉到 `postgres:15`，其它版本属于"理论可用"。
- **未找到 pgvector 等扩展需求**：截止 rc.6，new-api **没有** embedding / RAG / 向量召回相关 SQL；纯 OpenAI-compatible gateway。
- **`PreferSimpleProtocol: true` 与 pgbouncer**：源码已开启 simple protocol，理论上兼容 pgbouncer transaction mode，但官方 README 未明确推荐配 pgbouncer，生产场景需自测。
- **`LOG_SQL_DSN` 拆分日志库**：源码支持但官方文档少有提及；如需把 logs 表放到独立 PG，需要分别保证两个库都有 `public` schema 权限。
- **DB schema migration 工具**：未单独提供（GORM AutoMigrate 自动跑），无 alembic/flyway 类工具，无法 down-grade。
