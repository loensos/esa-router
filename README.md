# ESA Router

分流器：按 WebSocket Path 路由到不同后端

## 功能

- 配置文件路由（config.toml）
- 支持 SIGHUP 热插拔重载配置
- 可配置监听端口
- 纯 TCP 透传，不解构 Trojan 协议

## 安装

```bash
git clone https://github.com/loensos/esa-router.git
cd esa-router
go build -o esa-router main.go
mkdir -p /opt/esa-router
cp config.toml esa-router /opt/esa-router/
/opt/esa-router/esa-router
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

## 许可

MIT
