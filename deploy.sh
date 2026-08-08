#!/bin/bash
# ESA Router 部署脚本
# 用法: ./deploy.sh [GitHub URL] [监听端口]

set -e

GITHUB_URL="${1:-https://github.com/loensos/esa-router.git}"
LISTEN_PORT="${2:-1000}"
INSTALL_DIR="/opt/esa-router"
SYSTEMD_NAME="esa-router"

echo "=== ESA Router 部署脚本 ==="
echo ""

# 检查root权限
if [ "$EUID" -ne 0 ]; then
    echo "请使用 root 权限运行此脚本"
    exit 1
fi

# 创建安装目录
echo "1. 创建安装目录: $INSTALL_DIR"
mkdir -p "$INSTALL_DIR"

# 克隆仓库
echo "2. 克隆仓库: $GITHUB_URL"
cd /tmp
rm -rf esa-router
git clone "$GITHUB_URL"
cd esa-router

# 编译
echo "3. 编译..."
go build -o esa-router main.go

# 生成配置
echo "4. 生成配置文件"
cat > config.toml << EOF
# ESA Router 配置
listen = ":${LISTEN_PORT}"

# 路由配置: path backend
/ws-us [2602:f66f:10:6b65::1]:30927
/ws-sg [2406:4440:20:28::a]:30932
EOF

# 复制文件
echo "5. 安装到 $INSTALL_DIR"
cp esa-router "$INSTALL_DIR/"
cp config.toml "$INSTALL_DIR/"

# 设置权限
chmod +x "$INSTALL_DIR/esa-router"

# 创建 systemd 服务
echo "6. 创建 systemd 服务"
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

[Install]
WantedBy=multi-user.target
EOF

# 启动服务
echo "7. 启动服务..."
systemctl daemon-reload
systemctl enable $SYSTEMD_NAME
systemctl start $SYSTEMD_NAME

echo ""
echo "=== 部署完成 ==="
echo "安装目录: $INSTALL_DIR"
echo "监听端口: $LISTEN_PORT"
echo "查看日志: journalctl -u $SYSTEMD_NAME -f"
