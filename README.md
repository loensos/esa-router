# ESA Router v1.5.2

TCP 透传路由器：按 WebSocket 路径动态路由到不同后端，支持精确/范围/通配符三种匹配和 TCP Keepalive。

## 核心特性

- ✅ 配置文件路由 (`config.toml`)
- ✅ 多种匹配模式：精确、范围、通配符
- ✅ 可配置端口范围（`min_port` / `max_port`）
- ✅ 范围匹配优先于通配符匹配
- ✅ SIGHUP 热重载（不中断现有连接）
- ✅ 优雅关闭 (SIGTERM)
- ✅ 纯 TCP 透传，不解构 Trojan/VLESS/VMess 协议
- ✅ TCP Keepalive (向 ESA/CDN 方向，30秒间隔)
- ✅ CLI 参数支持 (--port, ESA_PORT)
- ✅ systemd 集成

## 架构

```
客户端 → 阿里云 ESA CDN (HTTPS 443) → VPS:7826 (esa-router) → 127.0.0.1:<port> (后端) → 落地
```

**为什么是 TCP 透传：** ESA Router 在 L4 层做字节流转发，不解析应用层协议。客户端到 ESA CDN 用 WebSocket+TLS，进入 VPS 后用 HTTP/1.1 转发（实际是 TCP 透传）。后端可以是任何 TCP 协议（Trojan、Shadowsocks、VLESS 等）。

## 安装

### 一键安装（推荐）

```bash
# 使用 GitHub API 绕过 CDN 缓存
curl -sL https://api.github.com/repos/loensos/esa-router/contents/deploy.sh -o deploy.sh
chmod +x deploy.sh
bash deploy.sh
```

部署脚本提供菜单：
1. 全新安装
2. 更新二进制
3. 设置参数
4. 检查更新
5. 卸载
6. 退出

### 手动安装

```bash
# 下载预编译二进制 (v1.5.2)
wget https://github.com/loensos/esa-router/releases/download/v1.5.2/esa-router-v1.5-linux-amd64
chmod +x esa-router-v1.5-linux-amd64
mv esa-router-v1.5-linux-amd64 /usr/local/bin/esa-router

# 写入 systemd service
cat > /etc/systemd/system/esa-router.service << 'EOF'
[Unit]
Description=ESA Router - WebSocket Path Router
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/esa-router /etc/esa-router/config.toml
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable esa-router
systemctl start esa-router
```

## 配置说明

配置文件路径：`/etc/esa-router/config.toml`

### 新格式（v1.5.2+）

使用 `[[routers]]` 数组语法，每条路由一个 table。

### 1. 通配符模式（所有端口）

```toml
listen_port = 7826

[[routers]]
path = "/node-*"
backend = "127.0.0.1:<port>"
```

**用法：**
- `/node-21581` → 路由到 `127.0.0.1:21581`
- `/node-30927` → 路由到 `127.0.0.1:30927`
- 后端端口变更无需修改配置

### 2. 范围模式（指定端口范围）

```toml
listen_port = 7826

[[routers]]
path = "/node-"
backend = "127.0.0.1:<port>"
min_port = 20001
max_port = 30000
```

**用法：**
- `/node-25000` → 路由到 `127.0.0.1:25000`（在范围内）
- `/node-2200` → 被拒绝（超出 20001-30000 范围）

### 3. 静态路由

```toml
listen_port = 7826

[[routers]]
path = "/node-us"
backend = "127.0.0.1:30927"

[[routers]]
path = "/node-sg"
backend = "127.0.0.1:21580"
```

**用法：**
- 客户端配置 path `/node-us` → 路由到 `127.0.0.1:30927`
- 客户端配置 path `/node-sg` → 路由到 `127.0.0.1:21580`

### 4. 混合模式（推荐）

```toml
listen_port = 7826

[[routers]]
path = "/node-30925"
backend = "127.0.0.1:30925"

[[routers]]
path = "/node-30926"
backend = "127.0.0.1:30926"

[[routers]]
path = "/node-*"
backend = "127.0.0.1:<port>"

[[routers]]
path = "/node-"
backend = "127.0.0.1:<port>"
min_port = 20001
max_port = 30000
```

**优先级：精确匹配 > 范围匹配 > 通配符匹配**

- `/node-30925` → 精确匹配成功 → `127.0.0.1:30925`
- `/node-25000` → 范围匹配成功（20001-30000）→ `127.0.0.1:25000`
- `/node-2200` → 范围匹配失败，通配符匹配成功 → `127.0.0.1:2200`

## 阿里云 ESA 控制台配置

**规则名称：** 自定义（如 `node-美国`）

**匹配条件：**
- 字段：URL 路径
- 匹配方式：开头为
- 匹配值：`/node`

**回源：**
- 协议：HTTP
- 端口：你的 router 监听端口（如 `7826` 或 `1000`）

**客户端配置（VPN 软件）：**
- 地址：你的 ESA 域名
- 端口：443
- 传输协议：WebSocket (WS)
- 路径：`/node-<port>`（如 `/node-30925`）
- TLS：开启

## CLI 参数

```bash
# 通过命令行指定端口（覆盖配置）
esa-router /etc/esa-router/config.toml --port=7826

# 通过环境变量
ESA_PORT=7826 esa-router /etc/esa-router/config.toml
```

## 运行时管理

```bash
# 查看状态
systemctl status esa-router

# 实时日志
tail -f /var/log/esa-router.log

# 热重载配置（不中断现有连接）
kill -1 $(pgrep esa-router)
# 或
systemctl reload esa-router

# 重启服务
systemctl restart esa-router

# 停止
systemctl stop esa-router
```

## 阿里云 ESA CDN 节点 IP 段

ESA 通过 IPv6 连接 router。VPS 需要：
- ✅ 启用 IPv6
- ✅ 防火墙允许 7826 端口（或你配置的端口）

## 故障排除

### ESA WebSocket 节点全超时

1. 检查 router 进程：`ps aux | grep esa-router`
2. 检查 router 日志：`tail -f /var/log/esa-router.log`
3. 检查端口监听：`ss -tlnp | grep 7826`
4. 测试连通性：`curl http://127.0.0.1:7826/node-test`（应返回 404）

### 配置加载失败

检查 TOML 格式，确保：
- 使用 `[[routers]]` 数组语法（不是 `[routers]` section）
- 每条路由用 `path = "..."` 和 `backend = "..."` 多行格式
- 字符串值用双引号

### systemd 启动失败

查看详细错误：
```bash
systemctl status esa-router
journalctl -u esa-router -n 50 --no-pager
```

## 卸载

```bash
bash deploy.sh
# 选择 5) 卸载
```

或手动：
```bash
systemctl stop esa-router
systemctl disable esa-router
rm /etc/systemd/system/esa-router.service
rm /usr/local/bin/esa-router
rm -rf /etc/esa-router
```

## 升级版本

```bash
bash deploy.sh
# 选择 2) 更新二进制
# 脚本会从 GitHub 下载最新版本
```

## 许可

MIT
