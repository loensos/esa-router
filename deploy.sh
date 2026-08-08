#!/bin/bash
# ESA Router 安装脚本
# 用法: curl -sSL https://raw.githubusercontent.com/loensos/esa-router/main/deploy.sh | bash

set -e

VERSION="1.0"
REPO="loensos/esa-router"
INSTALL_DIR="/opt/esa-router"
CONFIG_DIR="/etc/esa-router"
SYSTEMD_NAME="esa-router"

# 检测系统架构
ARCH=$(uname -m)
case "$ARCH" in
    x86_64|amd64) BIN_NAME="esa-router-linux-amd64" ;;
    aarch64|arm64) BIN_NAME="esa-router-linux-arm64" ;;
    *) echo "不支持的架构: $ARCH"; exit 1 ;;
esac

echo "=== ESA Router 安装脚本 v${VERSION} ==="
echo ""
echo "选择安装方式:"
echo "  1) 预编译二进制 (推荐，无需编译)"
echo "  2) 从源码编译"
echo ""
read -p "请选择 [1/2] " choice

if [ "$choice" != "2" ]; then
    echo ""
    echo "1. 下载预编译二进制: $BIN_NAME"
    BIN_URL="https://github.com/$REPO/releases/download/v${VERSION}/$BIN_NAME"
    curl -sL "$BIN_URL" -o /tmp/$BIN_NAME
    chmod +x /tmp/$BIN_NAME
    echo "   下载成功: $(ls -lh /tmp/$BIN_NAME | awk '{print $5}')"
    echo ""
    
    echo "2. 安装二进制到 $INSTALL_DIR"
    mkdir -p "$INSTALL_DIR"
    mv /tmp/$BIN_NAME "$INSTALL_DIR/$BIN_NAME"
    ln -sf "$INSTALL_DIR/$BIN_NAME" "$INSTALL_DIR/esa-router"
    echo "   安装完成"
    echo ""
else
    echo ""
    echo "1. 克隆仓库"
    cd /tmp
    git clone https://github.com/$REPO.git
    cd esa-router
    echo "   克隆完成"
    echo ""
    
    echo "2. 编译源码"
    go version
    go build -o esa-router .
    echo "   编译成功: $(ls -lh esa-router | awk '{print $5}')"
    echo ""
    
    echo "3. 安装到 $INSTALL_DIR"
    mkdir -p "$INSTALL_DIR"
    cp esa-router "$INSTALL_DIR/esa-router"
    ln -sf "$INSTALL_DIR/esa-router" "$INSTALL_DIR/$BIN_NAME"
    echo "   安装完成"
    echo ""
fi

# 创建配置
echo "4. 创建配置 $CONFIG_DIR/config.toml"
mkdir -p "$CONFIG_DIR"
if [ ! -f "$CONFIG_DIR/config.toml" ]; then
    cat > "$CONFIG_DIR/config.toml" << 'CONF'
# ESA Router 配置
listen = ":1000"

/ws-us [IPv6]:port
/ws-sg [IPv6]:port
CONF
    echo "   已创建示例配置"
else
    echo "   配置已存在，跳过"
fi
echo ""

# 安装systemd服务
echo "5. 安装systemd服务"
cat > /etc/systemd/system/$SYSTEMD_NAME.service << 'SERVICE'
[Unit]
Description=ESA Router
After=network.target

[Service]
Type=simple
ExecStart=/opt/esa-router/esa-router
WorkingDirectory=/etc/esa-router
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
SERVICE

systemctl daemon-reload
systemctl enable $SYSTEMD_NAME
echo "   服务已安装"
echo ""

# 启动服务
echo "6. 启动服务"
systemctl restart $SYSTEMD_NAME
sleep 1

if systemctl is-active --quiet $SYSTEMD_NAME; then
    echo "   ✅ 服务运行中"
else
    echo "   ❌ 服务启动失败"
    journalctl -u $SYSTEMD_NAME -n 20
    exit 1
fi
echo ""

echo "=== 安装完成 ==="
echo "二进制: $INSTALL_DIR/esa-router"
echo "配置: $CONFIG_DIR/config.toml"
echo "服务: $SYSTEMD_NAME"
echo ""
echo "管理命令:"
echo "  systemctl status $SYSTEMD_NAME    # 查看状态"
echo "  systemctl restart $SYSTEMD_NAME    # 重启服务"
echo "  kill -1 $(pgrep esa-router)       # 热重载配置"
echo ""
echo "GitHub: https://github.com/$REPO"
