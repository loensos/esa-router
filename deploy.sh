#!/bin/bash
# ESA Router 安装脚本
# 用法: curl -sSL https://raw.githubusercontent.com/loensos/esa-router/main/deploy.sh | bash
# 交互模式: bash deploy.sh

set -e

VERSION="1.1"
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

# 检测是否交互模式
INTERACTIVE=false
if [ -t 0 ]; then
    INTERACTIVE=true
fi

# 选择安装方式
if $INTERACTIVE; then
    echo "选择安装方式:"
    echo "  1) 预编译二进制 (推荐，无需编译)"
    echo "  2) 从源码编译"
    read -p "请选择 [1/2] " choice
else
    # 非交互模式，使用环境变量或默认值
    choice="${INSTALL_MODE:-1}"
    echo "使用默认安装方式: 预编译二进制"
fi

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

# 创建配置目录
mkdir -p "$CONFIG_DIR"
CONFIG_FILE="$CONFIG_DIR/config.toml"

# 配置路由
if $INTERACTIVE; then
    echo ""
    echo "=== 配置 ESA Router ==="
    echo ""
    
    # 监听端口
    read -p "监听端口 [1000]: " listen_port
    listen_port=${listen_port:-1000}
    
    # 路由配置
    echo ""
    echo "添加路由 (格式: /路径 = ip:端口)"
    echo "例如: /ws-us = 127.0.0.1:2000"
    echo "输入空行结束添加"
    echo ""
    
    route_count=0
    while true; do
        read -p "路由 $((route_count + 1)) (路径=后端): " route_input
        
        # 空行结束
        if [ -z "$route_input" ]; then
            break
        fi
        
        # 解析路径和后端
        path=$(echo "$route_input" | cut -d'=' -f1 | tr -d ' ')
        backend=$(echo "$route_input" | cut -d'=' -f2 | tr -d ' ')
        
        if [ -z "$path" ] || [ -z "$backend" ]; then
            echo "   格式错误，跳过"
            continue
        fi
        
        echo "  \"$path\" = \"$backend\"" >> "$CONFIG_FILE"
        route_count=$((route_count + 1))
    done
    
    if [ $route_count -eq 0 ]; then
        echo "  未配置路由，使用默认示例"
        echo '  "/ws-us" = "127.0.0.1:2000"' >> "$CONFIG_FILE"
        echo '  "/ws-sg" = "127.0.0.1:2001"' >> "$CONFIG_FILE"
        route_count=2
    fi
else
    # 非交互模式，使用环境变量或默认值
    listen_port="${LISTEN_PORT:-1000}"
    route_count=0
    
    # 清空配置
    > "$CONFIG_FILE"
    echo "listen_port = $listen_port" >> "$CONFIG_FILE"
    echo "" >> "$CONFIG_FILE"
    echo "[routers]" >> "$CONFIG_FILE"
    
    # 从环境变量读取路由，格式: ROUTES="/ws-us=127.0.0.1:2000,/ws-sg=127.0.0.1:2001"
    if [ -n "$ROUTES" ]; then
        IFS=',' read -ra ROUTE_ARRAY <<< "$ROUTES"
        for route in "${ROUTE_ARRAY[@]}"; do
            path=$(echo "$route" | cut -d'=' -f1)
            backend=$(echo "$route" | cut -d'=' -f2)
            if [ -n "$path" ] && [ -n "$backend" ]; then
                echo "  \"$path\" = \"$backend\"" >> "$CONFIG_FILE"
                route_count=$((route_count + 1))
            fi
        done
    fi
    
    # 默认路由
    if [ $route_count -eq 0 ]; then
        echo "  /ws-us -> 127.0.0.1:2000 (default)"
        echo "  /ws-sg -> 127.0.0.1:2001 (default)"
        echo '  "/ws-us" = "127.0.0.1:2000"' >> "$CONFIG_FILE"
        echo '  "/ws-sg" = "127.0.0.1:2001"' >> "$CONFIG_FILE"
        route_count=2
    fi
fi

echo ""
echo "配置已保存到: $CONFIG_FILE"
echo ""
echo "当前配置:"
cat "$CONFIG_FILE" | sed 's/^/   /'
echo ""

# 安装systemd服务
echo "3. 安装systemd服务"
cat > /etc/systemd/system/$SYSTEMD_NAME.service << 'SERVICE'
[Unit]
Description=ESA Router
After=network.target

[Service]
Type=simple
ExecStart=/opt/esa-router/esa-router /etc/esa-router/config.toml
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
echo "4. 启动服务"
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
echo "配置: $CONFIG_FILE"
echo "路由数: $route_count"
echo "监听端口: $listen_port"
echo "服务: $SYSTEMD_NAME"
echo ""
echo "管理命令:"
echo "  systemctl status $SYSTEMD_NAME    # 查看状态"
echo "  systemctl restart $SYSTEMD_NAME    # 重启服务"
echo "  kill -1 \$(pgrep esa-router)       # 热重载配置"
echo ""
echo "GitHub: https://github.com/$REPO"
