#!/bin/bash
# ESA Router 安装脚本
# 用法: curl -sSL https://raw.githubusercontent.com/loensos/esa-router/main/deploy.sh | bash
# 交互模式: bash deploy.sh

set -e

VERSION="1.2"
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

# 检测当前安装状态
CURRENT_BIN="/opt/esa-router/esa-router"
CURRENT_CONFIG="/etc/esa-router/config.toml"
IS_INSTALLED=false

if [ -f "$CURRENT_BIN" ] || systemctl is-active --quiet "$SYSTEMD_NAME" 2>/dev/null; then
    IS_INSTALLED=true
fi

if $IS_INSTALLED; then
    echo "检测到已安装 ESA Router"
    if systemctl is-active --quiet "$SYSTEMD_NAME" 2>/dev/null; then
        echo "  服务状态: 运行中"
        CURRENT_PID=$(pgrep -f esa-router | head -1)
        echo "  PID: $CURRENT_PID"
    else
        echo "  服务状态: 已停止"
    fi
    if [ -f "$CURRENT_CONFIG" ]; then
        echo "  配置: 存在 ($CURRENT_CONFIG)"
        echo "  当前路由:"
        grep -E '^/\w+' "$CURRENT_CONFIG" 2>/dev/null | while read -r line; do
            echo "    $line"
        done
        grep -E '^\s*"/' "$CURRENT_CONFIG" 2>/dev/null | while read -r line; do
            echo "    $line"
        done
    fi
    echo ""
fi

# 选择操作
if $INTERACTIVE; then
    echo "请选择操作:"
    echo "  1) 全新安装 (覆盖所有文件)"
    echo "  2) 更新二进制 (保留配置)"
    echo "  3) 仅检查更新"
    echo ""
    read -p "请选择 [1/2/3] " choice
else
    choice="${OPERATION:-2}"
    echo "使用默认操作: 更新二进制"
fi

# 获取最新版本
echo ""
echo "检查最新版本..."
LATEST_RELEASE=$(curl -s "https://api.github.com/repos/$REPO/releases/latest" 2>/dev/null)
LATEST_TAG=$(echo "$LATEST_RELEASE" | grep -o '"tag_name": *"[^"]*"' | cut -d'"' -f4)
LATEST_URL="https://github.com/$REPO/releases/download/$LATEST_TAG/$BIN_NAME"

if [ -z "$LATEST_TAG" ]; then
    echo "无法获取最新版本信息"
    exit 1
fi

echo "  最新版本: $LATEST_TAG"
echo "  下载地址: $LATEST_URL"
echo ""

# 下载二进制
echo "下载二进制..."
curl -sL "$LATEST_URL" -o /tmp/$BIN_NAME
chmod +x /tmp/$BIN_NAME
echo "  下载成功: $(ls -lh /tmp/$BIN_NAME | awk '{print $5}')"
echo ""

# 根据操作执行
case "$choice" in
    1|全新安装)
        echo "=== 全新安装 ==="
        echo ""
        
        # 停止服务
        if systemctl is-active --quiet "$SYSTEMD_NAME" 2>/dev/null; then
            echo "停止服务..."
            systemctl stop "$SYSTEMD_NAME"
            sleep 1
        fi
        
        # 安装二进制
        echo "安装二进制到 $INSTALL_DIR"
        mkdir -p "$INSTALL_DIR"
        cp /tmp/$BIN_NAME "$INSTALL_DIR/$BIN_NAME"
        ln -sf "$INSTALL_DIR/$BIN_NAME" "$INSTALL_DIR/esa-router"
        echo "  安装完成"
        echo ""
        
        # 配置（新建或保留）
        CONFIG_DIR="$CONFIG_DIR"
        CONFIG_FILE="$CONFIG_DIR/config.toml"
        mkdir -p "$CONFIG_DIR"
        
        if [ -f "$CONFIG_FILE" ]; then
            echo "保留现有配置: $CONFIG_FILE"
            echo "  请手动修改配置或删除后重新运行"
        else
            echo "创建新配置..."
            if $INTERACTIVE; then
                # 交互配置
                read -p "监听端口 [1000]: " listen_port
                listen_port=${listen_port:-1000}
                
                echo "添加路由 (格式: /路径 = ip:端口)"
                echo "例如: /ws-us = 127.0.0.1:2000"
                echo "动态路由: /node-* = 127.0.0.1:<port>"
                echo "输入空行结束添加"
                echo ""
                
                route_count=0
                while true; do
                    read -p "路由 $((route_count + 1)) (路径=后端): " route_input
                    if [ -z "$route_input" ]; then
                        break
                    fi
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
                    echo '  "/ws-us" = "127.0.0.1:2000"' >> "$CONFIG_FILE"
                    echo '  "/node-*" = "127.0.0.1:<port>"' >> "$CONFIG_FILE"
                    route_count=2
                fi
            else
                # 非交互，使用环境变量
                listen_port="${LISTEN_PORT:-1000}"
                route_count=0
                
                cat > "$CONFIG_FILE" << EOF
# ESA Router 配置
# 监听端口
listen_port = $listen_port

# 路由列表
[routers]
EOF
                
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
                
                if [ $route_count -eq 0 ]; then
                    echo '  "/ws-us" = "127.0.0.1:2000"' >> "$CONFIG_FILE"
                    echo '  "/node-*" = "127.0.0.1:<port>"' >> "$CONFIG_FILE"
                    route_count=2
                fi
            fi
            echo "  配置已创建: $CONFIG_FILE"
        fi
        echo ""
        
        # 安装 systemd 服务
        echo "安装 systemd 服务..."
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
        echo "  服务已安装"
        echo ""
        
        # 启动服务
        echo "启动服务..."
        systemctl start $SYSTEMD_NAME
        sleep 1
        
        if systemctl is-active --quiet $SYSTEMD_NAME; then
            echo "  ✅ 服务运行中"
        else
            echo "  ❌ 服务启动失败"
            journalctl -u $SYSTEMD_NAME -n 20
            exit 1
        fi
        ;;
        
    2|更新)
        echo "=== 更新二进制 ==="
        echo ""
        
        # 停止服务
        if systemctl is-active --quiet "$SYSTEMD_NAME" 2>/dev/null; then
            echo "停止服务..."
            systemctl stop "$SYSTEMD_NAME"
            sleep 1
        fi
        
        # 确保进程已停止
        for i in 1 2 3; do
            if pgrep -f esa-router > /dev/null 2>&1; then
                echo "  等待进程退出... ($i/3)"
                sleep 1
            fi
        done
        pkill -9 esa-router 2>/dev/null || true
        sleep 1
        
        # 安装新二进制
        echo "安装新二进制..."
        mkdir -p "$INSTALL_DIR"
        cp /tmp/$BIN_NAME "$INSTALL_DIR/$BIN_NAME"
        ln -sf "$INSTALL_DIR/$BIN_NAME" "$INSTALL_DIR/esa-router"
        echo "  安装完成"
        echo ""
        
        # 保留现有配置
        if [ -f "$CONFIG_FILE" ]; then
            echo "保留现有配置: $CONFIG_FILE"
            route_count=$(grep -E '^\s*"/' "$CONFIG_FILE" | wc -l)
            if [ $route_count -eq 0 ]; then
                route_count=$(grep -E '^[^#]' "$CONFIG_FILE" | grep -v "listen" | grep -v "^$" | grep -v "^\[" | grep -v "=" | wc -l)
            fi
            echo "  路由数: $route_count"
        else
            echo "  警告: 未找到配置文件，将使用默认配置"
        fi
        echo ""
        
        # 启动服务
        echo "启动服务..."
        systemctl start $SYSTEMD_NAME
        sleep 1
        
        if systemctl is-active --quiet $SYSTEMD_NAME; then
            echo "  ✅ 服务运行中"
        else
            echo "  ❌ 服务启动失败"
            journalctl -u $SYSTEMD_NAME -n 20
            exit 1
        fi
        ;;
        
    3|检查)
        echo "=== 检查更新 ==="
        echo ""
        echo "当前版本: 未检测"
        echo "最新版本: $LATEST_TAG"
        
        if [ -f "$CURRENT_BIN" ]; then
            CURRENT_VERSION=$(ldd "$CURRENT_BIN" 2>/dev/null | head -1 || echo "未知")
            echo "当前版本信息: $CURRENT_VERSION"
        fi
        
        if [ "$LATEST_TAG" = "v${VERSION}" ]; then
            echo "  ✅ 已是最新版本"
        else
            echo "  ⚠️  有新版本可用，请运行更新"
        fi
        ;;
esac

echo ""
echo "=== 安装完成 ==="
echo "二进制: $INSTALL_DIR/esa-router"
echo "配置: $CONFIG_FILE"
echo "服务: $SYSTEMD_NAME"
echo "版本: $LATEST_TAG"
echo ""
echo "管理命令:"
echo "  systemctl status $SYSTEMD_NAME    # 查看状态"
echo "  systemctl restart $SYSTEMD_NAME    # 重启服务"
echo "  kill -1 \$(pgrep esa-router)       # 热重载配置"
echo ""
echo "GitHub: https://github.com/$REPO"
