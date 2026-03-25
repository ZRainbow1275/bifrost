# Bifrost 真实服务器测试方案 (2026-03-25)

## 测试环境

| 角色 | OS | 配置 | 网络 |
|------|------|------|------|
| Server B (海外) | Ubuntu 22.04 | 1C1G 20GB SSD | 公网 IP, 带宽 ≥ 30Mbps |
| Server A (国内) | Ubuntu 22.04 | 2C4G 40GB SSD | 公网 IP, 带宽 ≥ 10Mbps, 域名 |
| 客户端 | 任意 | WireGuard + curl | 可达 Server A |

前置条件:
- Server A 可 SSH 登录 Server B
- Server A 有 ICP 备案域名（或跳过 Caddy TLS）
- 已修复 AUDIT-REPORT.md 中的 4 个 BLOCKER

---

## Step 0: 基础连通性

```bash
# 本地 → Server B
ssh root@<B_IP> "uname -a && docker --version"

# 本地 → Server A
ssh root@<A_IP> "uname -a && docker --version"

# Server A → Server B
ssh root@<A_IP> "curl -so /dev/null -w '%{http_code}' --connect-timeout 5 https://<B_IP>:443"
```

| 检查项 | 期望 |
|--------|------|
| SSH 可登录 | 输出系统信息 |
| Docker ≥ 20.10 | 版本号 ≥ 20.10 |
| A→B 443 可达 | 非超时的 HTTP 状态码 |

---

## Step 1: Server B 部署

```bash
ssh root@<B_IP>
git clone https://github.com/ZRainbow1275/bifrost.git
cd bifrost && chmod +x install.sh scripts/*.sh
sudo ./install.sh --server-b
```

### 验证清单

```bash
# 1.1 Xray 运行
systemctl is-active xray && echo "PASS" || echo "FAIL"

# 1.2 端口监听（注意：Xray 不应该用 443）
ss -tlnp | grep xray

# 1.3 防火墙开放
ufw status | grep $(ss -tlnp | grep xray | awk '{print $4}' | cut -d: -f2)

# 1.4 Caddy 运行（如启用域名）
systemctl is-active caddy 2>/dev/null && echo "PASS" || echo "SKIP"

# 1.5 无端口冲突
[ $(ss -tlnp | grep ':443 ' | wc -l) -le 1 ] && echo "PASS" || echo "FAIL: 443端口冲突"

# 1.6 Xray 配置有效
python3 -m json.tool /usr/local/etc/xray/config.json > /dev/null && echo "PASS" || echo "FAIL"

# 1.7 记录连接信息（Step 2 需要）
cat /root/bifrost/server-b-info.txt 2>/dev/null || echo "手动从部署输出记录"
```

---

## Step 2: Server A 部署

```bash
ssh root@<A_IP>
git clone https://github.com/ZRainbow1275/bifrost.git
cd bifrost && chmod +x install.sh scripts/*.sh
sudo ./install.sh --server-a
# 输入 Step 1 的连接信息
```

### 验证清单

```bash
# 2.1 Xray 客户端运行
systemctl is-active xray && echo "PASS" || echo "FAIL"

# 2.2 隧道连通 (P0 — 最关键测试)
curl -x socks5://127.0.0.1:10808 -so /dev/null -w '%{http_code}' \
  --connect-timeout 10 https://api.anthropic.com
# 期望: 200 或 401

# 2.3 NewAPI 容器
docker ps --format '{{.Names}} {{.Status}}' | grep new-api

# 2.4 NewAPI API 可达
curl -s http://127.0.0.1:3000/api/status | python3 -c "import json,sys;print(json.load(sys.stdin)['success'])"
# 期望: True

# 2.5 ⚠️ 立即修改默认密码
echo "登录 http://127.0.0.1:3000 用 root/123456 并改密码"

# 2.6 Caddy HTTPS (如有域名)
curl -sI https://<DOMAIN>/api/status | head -3
```

---

## Step 3: Mihomo 智能路由

```bash
sudo ./install.sh --mihomo
```

### 验证清单

```bash
# 3.1 服务运行
systemctl is-active mihomo && echo "PASS" || echo "FAIL"

# 3.2 AI 域名走代理
curl -x http://127.0.0.1:7890 -so /dev/null -w '%{http_code}' \
  --connect-timeout 10 https://api.openai.com/v1/models
# 期望: 401

# 3.3 国内直连
curl -x http://127.0.0.1:7890 -so /dev/null -w '%{http_code}' \
  --connect-timeout 5 https://www.baidu.com
# 期望: 200

# 3.4 流媒体拦截
curl -x http://127.0.0.1:7890 -so /dev/null -w '%{http_code}' \
  --connect-timeout 5 https://www.netflix.com
# 期望: 000 (连接被拒)

# 3.5 NewAPI 通过 Mihomo 代理上游
docker restart new-api && sleep 5
docker exec new-api curl -s https://api.anthropic.com -o /dev/null -w '%{http_code}' --connect-timeout 10
# 期望: 200 或 401
```

---

## Step 4: VPN + 用户管理

```bash
sudo ./install.sh --vpn
sudo ./install.sh --user-mgmt   # 选择添加用户
```

### 验证清单

```bash
# 4.1 WireGuard 运行
systemctl is-active wg-quick@wg0 && echo "PASS" || echo "FAIL"

# 4.2 端口监听
ss -ulnp | grep 51820 && echo "PASS" || echo "FAIL"

# 4.3 用户文件生成
ls /etc/bifrost/vpn/users/<username>/
ls /etc/bifrost/users/guides/<username>-guide.md
```

---

## Step 5: 客户端端到端测试

```bash
# 5.1 导入 VPN 配置到 WireGuard 客户端并连接

# 5.2 VPN 连通
ping -c 3 10.8.0.1

# 5.3 NewAPI 通过 VPN 可达
curl https://<DOMAIN>/api/status

# 5.4 ⭐ 最终测试：AI API 调用
curl -X POST https://<DOMAIN>/v1/chat/completions \
  -H "Authorization: Bearer <API_KEY>" \
  -H "Content-Type: application/json" \
  -d '{"model":"claude-sonnet-4-20250514","messages":[{"role":"user","content":"hi"}]}' \
  -w "\n%{http_code}\n"
# 期望: AI 返回响应 + HTTP 200
```

---

## Step 6: Bifrost API 管理平台

```bash
sudo bash scripts/bifrost-api.sh deploy
```

### 验证清单

```bash
# 6.1 容器运行
docker ps | grep bifrost-api

# 6.2 健康检查
curl http://127.0.0.1:8000/health

# 6.3 注册页面
curl -s https://<DOMAIN>/manage/register | grep -o '<title>.*</title>'

# 6.4 注册 API
curl -X POST https://<DOMAIN>/manage/api/v1/register \
  -H "Content-Type: application/json" \
  -d '{"username":"testuser01"}'

# 6.5 模型列表
curl https://<DOMAIN>/manage/api/v1/models

# 6.6 管理接口
curl -H "X-Admin-Key: <KEY>" https://<DOMAIN>/manage/api/v1/stats/overview
```

---

## Step 7: 回归测试矩阵

| # | 测试项 | 命令 | 期望 | 优先级 |
|---|--------|------|------|--------|
| 1 | Xray 隧道 | `curl -x socks5://127.0.0.1:10808 https://api.anthropic.com` | 200/401 | P0 |
| 2 | Mihomo AI 路由 | `curl -x http://127.0.0.1:7890 https://api.openai.com` | 401 | P0 |
| 3 | 白名单拦截 | `curl -x http://127.0.0.1:7890 https://www.netflix.com` | 000 | P0 |
| 4 | NewAPI 可达 | `curl http://127.0.0.1:3000/api/status` | success:true | P0 |
| 5 | VPN 连通 | `ping 10.8.0.1` | 可达 | P0 |
| 6 | AI 调用 | `POST /v1/chat/completions` | AI 响应 | P0 |
| 7 | 注册接口 | `POST /manage/api/v1/register` | api_key | P1 |
| 8 | 模型状态 | `GET /manage/api/v1/models` | 列表 | P1 |
| 9 | 国内直连 | `curl -x http://127.0.0.1:7890 https://www.baidu.com` | 200 | P1 |
| 10 | TLS 证书 | `curl -vI https://<DOMAIN>` | TLS 1.3 | P2 |
| 11 | 服务自启 | `reboot && systemctl status xray mihomo` | active | P2 |
| 12 | 健康检查 | `./install.sh --health-check` | 全绿 | P2 |
