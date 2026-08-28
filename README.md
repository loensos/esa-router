# ESA Router

TCP 透传路由器：按 WebSocket 路径动态路由到不同后端，支持范围匹配和 TCP Keepalive。
1、支持trojan+ws、vless+ws、vmess+ws等，落地协议不能配置tls。
2、ws路径写/node-端口，端口为转发端口不是落地端口，当然也可以/abc-20000 /abc与esa 回源规则一致即可。
3、在vpn软件里打开tls。tls的域名填写esa的域名 端口443。
4、esa回源规则：A、传入请求类型～选自定义规则～选url路径～开头为～/node ( node为例子，可为任意固定值，如此才能动态选端口。)
B、回源协议和端口～回源协议选 http ～ http端口可为任意端口，不与落地转发端口一样就行。

## 功能特性

- ✅ 配置文件路由 (config.toml)
- ✅ 支持 SIGHUP 热重载
- ✅ 端口热拔插（无需重启服务）
- ✅ 纯TCP透传，不解构 Trojan vless vmess协议
- ✅ 动态路由 `/node-*` 自动提取端口
- ✅ 范围匹配 `/node-20001-30000`
- ✅ 范围优先于通配符
- ✅ 自身端口保护（防止循环）
- ✅ TCP Keepalive (向 ESA/CDN 方向，30秒间隔)
- ✅ CLI 参数支持 (--port, ESA_PORT)

## 安装

### 交互式安装（推荐）

```bash
# 1. 下载脚本
curl -sSL https://raw.githubusercontent.com/loensos/esa-router/main/deploy.sh -o deploy.sh

# 2. 运行脚本（显示交互菜单）
bash deploy.sh
```

### 手动安装

```bash
# 下载预编译二进制
wget https://github.com/loensos/esa-router/releases/download/v1.5.1/esa-router-v1.5-linux-amd64
chmod +x esa-router-v1.5-linux-amd64
mv esa-router-v1.5-linux-amd64 /usr/local/bin/esa-router
```

## 配置说明

### 范围匹配（推荐用于特定端口范围）

```toml
listen_port = 1000

[routers]
  "/node-20001-30000" = "127.0.0.1:<port>"
```

**用法：**
- `/node-25000` → 路由到 `127.0.0.1:25000`（在范围内）
- `/node-2200` → 被拒绝（超出 20001-30000 范围）
- `/node-30927` → 被拒绝（超出范围）

### 通配符匹配（所有端口）

```toml
listen_port = 1000

[routers]
  "/node-*" = "127.0.0.1:<port>"
```

**用法：**
- `/node-21581` → 路由到 `127.0.0.1:21581`
- `/node-30927` → 路由到 `127.0.0.1:30927`
- 后端端口变更无需修改配置

### 混合模式（范围 + 通配符）

```toml
listen_port = 1000

[routers]
  "/node-*" = "127.0.0.1:<port>"
  "/node-20001-30000" = "127.0.0.1:<port>"
```

**优先级：范围匹配 > 通配符匹配**

- `/node-25000` → 范围匹配成功（20001-30000）
- `/node-2200` → 范围匹配失败，通配符匹配成功
- `/node-30927` → 范围匹配失败，通配符匹配成功

### 静态路由

```toml
listen_port = 1000

[routers]
  "/node-us" = "127.0.0.1:30927"
  "/node-sg" = "127.0.0.1:21580"
```

**用法：**
- 客户端配置 path: `/node-us` → 路由到 `127.0.0.1:30927`
- 客户端配置 path: `/node-sg` → 路由到 `127.0.0.1:21580`

## 热重载

```bash
# 修改配置后
vi /etc/esa-router/config.toml
kill -1 $(pgrep esa-router)

# 或重启服务
systemctl restart esa-router
```

## 示例场景

### 场景 1：只允许特定端口范围

```toml
[routers]
  "/node-20001-30000" = "127.0.0.1:<port>"
```
- 21580 ✓ (在范围内)
- 30927 ✗ (超出范围)

### 场景 2：所有端口都允许

```toml
[routers]
  "/node-*" = "127.0.0.1:<port>"
```
- 21580 ✓
- 30927 ✓
- 任意端口都通

### 场景 3：主要端口用通配符，敏感端口用范围限制

```toml
[routers]
  "/node-*" = "127.0.0.1:<port>"
  "/node-50000-60000" = "127.0.0.1:<port>"  # 只允许 50000-60000
```

## 许可

MIT
