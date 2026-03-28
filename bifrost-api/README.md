# Bifrost 管理平台

Bifrost 的 API 管理服务，对 NewAPI 的 REST API 进行封装，提供用户注册、模型状态监控、渠道管理等功能。

## 功能

- **用户自助注册（注册机）** — 用户通过 Web 页面自助注册，自动创建 NewAPI 账户和 API Token
- **批量用户创建** — 管理员通过 API 批量创建用户账户
- **模型可用性监控** — 查看所有可用模型及其渠道分布
- **渠道管理与测试** — 查看、创建、测试上游渠道连通性
- **用量统计** — 全局和按用户的 API 用量统计

## 部署

### 环境要求

- Docker + Docker Compose（v2 插件）
- NewAPI 已部署并运行（端口 3000）
- NewAPI 的管理员 Token

### 快速部署

```bash
# 1. 进入项目目录
cd bifrost-api

# 2. 配置环境变量
cp .env.example .env
vim .env   # 填入 NewAPI admin token 等配置

# 3. 构建并启动
docker compose up -d

# 4. 查看日志
docker compose logs -f

# 5. 验证部署
curl http://127.0.0.1:8000/health
```

### 配置说明

| 变量 | 说明 | 默认值 |
|------|------|--------|
| `BIFROST_NEWAPI_ADMIN_TOKEN` | NewAPI 管理员 Token（必填） | - |
| `BIFROST_ADMIN_KEY` | Bifrost 管理密钥，用于 `X-Admin-Key` 头 | - |
| `BIFROST_PUBLIC_BASE_URL` | 返回给用户的 AI 网关外部地址（必填） | - |
| `BIFROST_ALLOW_SELF_REGISTER` | 是否允许用户自助注册 | `true` |
| `BIFROST_DEFAULT_QUOTA` | 新用户默认配额（USD） | `100` |
| `BIFROST_MAX_REGISTER_PER_DAY` | 每日最大成功注册数 | `50` |
| `BIFROST_RATE_LIMIT_PER_MINUTE` | 每分钟最大注册尝试数 | `30` |
| `BIFROST_CORS_ALLOW_ORIGINS` | 允许的跨域来源列表（逗号分隔） | 空 |

### 获取 NewAPI Admin Token

```bash
# 方式 1: 从文件读取（如果之前部署过用户管理）
cat /etc/bifrost/.new-api-admin-token

# 方式 2: 从 Docker 容器环境变量获取
docker exec new-api printenv ADMIN_TOKEN
```

## API 文档

部署后访问交互式 API 文档：

- **Swagger UI**: `http://your-server:8000/docs`
- **ReDoc**: `http://your-server:8000/redoc`

如果通过 Caddy 反向代理访问：

- **Swagger UI**: `https://your-domain/manage/docs`
- **ReDoc**: `https://your-domain/manage/redoc`
- **注册页面**: `https://your-domain/manage/register`

## API 端点一览

### 公开端点

| 方法 | 路径 | 说明 |
|------|------|------|
| `GET` | `/` | API 信息 |
| `GET` | `/health` | 健康检查 |

### 注册端点

| 方法 | 路径 | 说明 |
|------|------|------|
| `POST` | `/api/v1/register` | 用户自助注册 |
| `GET` | `/register` | 注册页面（Web UI） |

### 管理端点（需要 `X-Admin-Key` 头）

| 方法 | 路径 | 说明 |
|------|------|------|
| `GET` | `/api/v1/users` | 用户列表 |
| `POST` | `/api/v1/users/batch` | 批量创建用户 |
| `PUT` | `/api/v1/users/{id}/quota` | 更新用户配额 |
| `DELETE` | `/api/v1/users/{id}` | 删除用户 |
| `GET` | `/api/v1/models/test` | 主动测试模型可用性 |
| `GET` | `/api/v1/channels` | 渠道列表 |
| `POST` | `/api/v1/channels/{id}/test` | 测试渠道 |
| `GET` | `/api/v1/stats/overview` | 系统总览统计 |

### 公开只读端点

| 方法 | 路径 | 说明 |
|------|------|------|
| `GET` | `/api/v1/models` | 模型状态聚合查询 |
| `GET` | `/api/v1/register/status` | 注册可用性与名额查询 |

## 架构

```
用户浏览器
    |
    v
  Caddy (TLS) -- /manage/* --> Bifrost API (:8000)
    |                               |
    v                               v
  /v1/* /api/* --> NewAPI (:3000) <--+
```

Bifrost API 不直接处理 AI 请求，只封装 NewAPI 的管理 API，提供更友好的注册和监控界面。
