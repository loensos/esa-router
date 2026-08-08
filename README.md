# ESA Router v1.2

WebSocket Path 路由器：按路径动态路由到不同后端

## v1.2 新增功能

### 动态路由
- `/node-*` → 自动提取路径中的端口号，路由到 `127.0.0.1:<port>`
- 支持端口范围限制：`/node-20001-30000` → 只接受 20001-30000 端口
- 端口热拔插：后端端口变更无需修改路由器配置

### 静态路由
- 固定路径映射到固定后端
- 适合需要特定路径的场景

## 功能特性

- ✅ 配置文件路由 (config.toml)
- ✅ 支持 SIGHUP 热重载
- ✅ 端口热拔插（无需重启服务）
- ✅ 纯 TCP 透传，不解构 Trojan 协议
- ✅ 动态路由 `/node-*` 自动提取端口
- ✅ 范围匹配 `/node-20001-30000`
- ✅ 自身端口保护（防止循环）

## 安装

### 一键安装（推荐）

```bash
curl -sSL https://raw.githubusercontent.com/loensos/esa-router/main/deploy.sh | bash
```

### 手动安装

```bash
# 下载预编译二进制
wget https://github.com/loensos/esa-router/releases/download/v1.2/esa-router-linux-amd64
chmod +x esa-router-linux-amd64
mv esa-router-linux-amd64 /opt/esa-router/esa-router
```

## 配置说明

### 动态路由（推荐）

```toml
listen_port = 7826

[routers]
  "/node-*" = "127.0.0.1:<port>"
```

**用法：**
- 客户端配置 path: `/node-21581` → 自动路由到 `127.0.0.1:21581`
- 客户端配置 path: `/node-30927` → 自动路由到 `127.0.0.1:30927`
- 后端端口变更无需修改路由器配置

### 范围限制

```toml
listen_port = 7826

[routers]
  "/node-*" = "127.0.0.1:<port>"
  "/node-20001-30000" = "127.0.0.1:<port>"
```

**用法：**
- `/node-2200` → 路由到 `127.0.0.1:2200`（在范围内）
- `/node-5500` → 被拒绝（超出 20001-30000 范围）

### 静态路由

```toml
listen_port = 7826

[routers]
  "/node-us" = "127.0.0.1:30927"
  "/node-sg" = "127.0.0.1:21580"
```

**用法：**
- 客户端配置 path: `/node-us` → 路由到 `127.0.0.1:30927`
- 客户端配置 path: `/node-sg` → 路由到 `127.0.0.1:21580`

### 混合模式

```toml
listen_port = 7826

[routers]
  "/node-us" = "127.0.0.1:30927"
  "/node-sg" = "127.0.0.1:21580"
  "/node-*" = "127.0.0.1:<port>"
  "/node-20001-30000" = "127.0.0.1:<port>"
```

**优先级：** 静态路由 > 动态路由 > 范围路由

## 热重载

```bash
# 修改配置后
vi /etc/esa-router/config.toml
kill -1 $(pgrep esa-router)

# 或重启服务
systemctl restart esa-router
```

## Release 版本

- [v1.2](https://github.com/loensos/esa-router/releases/tag/v1.2) - 动态路由，端口热拔插
- [v1.1](https://github.com/loensos/esa-router/releases/tag/v1.1) - 标准 TOML 配置，SIGHUP 热重载
- [v1.0](https://github.com/loensos/esa-router/releases/tag/v1.0) - 初始版本

## 许可

MIT
