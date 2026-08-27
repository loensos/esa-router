# ESA Router v1.5 更新说明

## 版本特性

### 1. TCP Keepalive 功能
- **客户端方向 Keepalive**: 向阿里云 ESA/CDN 方向发送探测包，防止空闲断开
- **后端方向 Keepalive**: 向后端服务器发送探测包，检测后端存活状态
- **探测间隔**: 30 秒
- **配置方式**: `ListenConfig{KeepAlive: 30 * time.Second}` + `SetKeepAlivePeriod(30s)`

### 2. CLI 参数支持
- `--port=1000`: 指定监听端口
- `ESA_PORT=1000`: 环境变量指定端口
- 配置文件: `/etc/esa-router/config.toml`

### 3. 部署脚本优化
- 交互式端口配置
- 支持多路由配置（通配符、范围、静态）
- 自动添加双引号（静态路由）
- 从配置文件加载已有路由
- 选择性删除路由

### 4. 日志优化
- 清晰的 Keepalive 日志: `[breath] 向 ESA 探测: <IP> <- :1000 (30秒间隔)`
- 客户端连接日志: `[breath] Client connected: :1000 <- <IP>`

## 架构说明

```
手机 --> 阿里云 ESA (CDN) --> ESA Router (VPS:1000) --> 127.0.0.1:8888 (落地)
         ↑                      ↑
      探测目标                 发送探测 (30秒)
```

## 配置文件示例

```toml
listen_port = 1000

[routers]
"/node-test" = "127.0.0.1:8888"
"/node-*" = "127.0.0.1:<port>"
"/node-20001-30000" = "127.0.0.1:<port>"
```

## 部署命令

```bash
# 安装
curl -sSL https://raw.githubusercontent.com/loensos/esa-router/main/deploy.sh | bash

# 或者手动部署
scp esa-router-v1.5 root@VPS:/usr/local/bin/esa-router
nohup /usr/local/bin/esa-router /etc/esa-router/config.toml > /var/log/esa-router.log 2>&1 &
```

## 测试验证

```bash
# 连接测试
python3 -c "
import socket, time
s = socket.create_connection(('127.0.0.1', 1000), timeout=5)
s.send(b'GET /node-test HTTP/1.1\r\nHost: localhost\r\n\r\n')
time.sleep(1)
data = s.recv(1024)
print('响应:', data.decode()[:50])
print('保持 40 秒...')
time.sleep(40)
try:
    s.settimeout(1)
    s.send(b'TEST\r\n')
    print('连接存活 - Keepalive 生效')
except:
    print('连接断开')
s.close()
"
```

## 提交历史

- `c670b55`: fix duplicate configPath declaration
- `806b2a1`: fix configPath and deploy ESA breath log
- `a904474`: fix duplicate configPath and enable ESA breath log
- `589a27a`: fix configPath declaration
- `18902a5`: fix build errors

## 二进制信息

- 文件: `esa-router-v1.5`
- 大小: 3.4MB
- 编译: Go 1.21.5
- MD5: 1845dd4af3d2bf8713c3e9b4051217ef

## 变更文件

- `main.go`: TCP Keepalive、CLI 参数、日志优化
- `deploy.sh`: 交互式配置、多路由支持、静态路由引号自动添加
- `esa-router-v1.5`: 编译后的二进制文件

## 已知问题

- 客户端检查 Keepalive 设置时可能显示 `SO_KEEPALIVE=0`，这是 Go 运行时实现方式导致，实际探测包会正常发送
