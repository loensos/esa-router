# ESA Router

分流器：按 WebSocket Path 路由到不同后端

## 功能

- 配置文件路由（config.toml）
- 支持 SIGHUP 热插拔重载配置
- 可配置监听端口
- 纯 TCP 透传，不解构 Trojan 协议

## 安装

### 一键安装（推荐）

```bash
curl -sSL https://raw.githubusercontent.com/loensos/esa-router/main/deploy.sh | bash
```

### 手动安装

```bash
# 下载预编译二进制
wget https://github.com/loensos/esa-router/releases/download/v1.0/esa-router-linux-amd64
chmod +x esa-router-linux-amd64
mv esa-router-linux-amd64 /opt/esa-router/esa-router

# 或从源码编译
git clone https://github.com/loensos/esa-router.git
cd esa-router
go build -o esa-router main.go
mkdir -p /opt/esa-router
cp main.go go.mod config.toml /opt/esa-router/
cd /opt/esa-router
go build -o esa-router main.go
```

## 配置 (config.toml)

```toml
listen = ":1000"  # 监听端口，默认1000

/ws-us [IPv6]:port
/ws-sg [IPv6]:port
```

## 热插拔

```bash
vi /opt/esa-router/config.toml
kill -1 $(pgrep esa-router)
```

## Release

- [v1.0](https://github.com/loensos/esa-router/releases/tag/v1.0)
- 预编译二进制: [esa-router-linux-amd64](https://github.com/loensos/esa-router/releases/download/v1.0/esa-router-linux-amd64)

## 许可

MIT
