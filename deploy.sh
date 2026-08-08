#!/bin/bash
# ESA Router 部署脚本
# 用法: ./deploy.sh [监听端口]

set -e

LISTEN_PORT="${1:-1000}"
INSTALL_DIR="/opt/esa-router"
SYSTEMD_NAME="esa-router"

echo "=== ESA Router 部署脚本 ==="
echo ""

if [ "$EUID" -ne 0 ]; then
    echo "请使用 root 权限运行此脚本"
    exit 1
fi

echo "1. 创建安装目录: $INSTALL_DIR"
mkdir -p "$INSTALL_DIR"

if [ -f "main.go" ]; then
    echo "2. 发现源码目录，编译..."
    go build -o esa-router main.go
elif [ -f "/root/esa-router/main.go" ]; then
    echo "2. 从 /root/esa-router 复制源码..."
    cp /root/esa-router/main.go "$INSTALL_DIR/"
    cp /root/esa-router/go.mod "$INSTALL_DIR/"
    cd "$INSTALL_DIR"
    go build -o esa-router main.go
else
    echo "错误: 未找到源码，请先克隆仓库或复制源码到当前目录"
    exit 1
fi

echo "3. 生成配置文件"
cat > "$INSTALL_DIR/config.toml" << EOF
# ESA Router 配置
listen = ":${LISTEN_PORT}"

# 路由配置: path backend
/ws-us [2602:f66f:10:6b65::1]:30927
/ws-sg [2406:4440:20:28::a]:30932
EOF

chmod +x "$INSTALL_DIR/esa-router"

echo "4. 创建 systemd 服务"
cat > /etc/systemd/system/$SYSTEMD_NAME.service << EOF
[Unit]
Description=ESA Router
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=$INSTALL_DIR
ExecStart=$INSTALL_DIR/esa-router
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

echo "5. 启动服务..."
systemctl daemon-reload
systemctl enable $SYSTEMD_NAME
systemctl start $SYSTEMD_NAME

echo ""
echo "=== 部署完成 ==="
echo "安装目录: $INSTALL_DIR"
echo "配置文件: $INSTALL_DIR/config.toml"
echo "监听端口: $LISTEN_PORT"
echo ""
echo "查看日志: journalctl -u $SYSTEMD_NAME -f"
