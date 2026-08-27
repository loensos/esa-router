#!/bin/bash
# ESA Router 安装脚本 v1.3
# 用法: curl -sSL https://raw.githubusercontent.com/loensos/esa-router/main/deploy.sh | bash

set -e

VERSION="1.5"
REPO="loensos/esa-router"
GITHUB="https://github.com"
INSTALL_DIR="/usr/local/bin"
CONFIG_DIR="/etc/esa-router"
SERVICE_NAME="esa-router"

BINARY_NAME="esa-router-linux-amd64"
BINARY_PATH="$INSTALL_DIR/esa-router"
SYMLINK_PATH="$INSTALL_DIR/esa-router"
CONFIG_PATH="$CONFIG_DIR/config.toml"

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

check_root() {
    if [ "$EUID" -ne 0 ]; then
        error "请使用 root 用户运行: sudo bash $0"
    fi
}

check_os() {
    if ! command -v systemctl &> /dev/null; then
        error "需要 systemd 系统"
    fi
}

check_arch() {
    ARCH=$(uname -m)
    if [ "$ARCH" != "x86_64" ]; then
        error "仅支持 x86_64 架构，当前: $ARCH"
    fi
}

install_dependencies() {
    info "检查依赖..."
    if ! command -v curl &> /dev/null; then
        info "安装 curl..."
        apt-get update && apt-get install -y curl
    fi
}

create_directories() {
    info "创建目录..."
    mkdir -p "$INSTALL_DIR"
    mkdir -p "$CONFIG_DIR"
}

download_binary() {
    info "检查二进制文件..."
    # 优先级: 本地脚本目录 > /usr/local/bin (如果已存在且大小正确) > GitHub
    if [ -f "/root/esa-router/esa-router-v1.5" ]; then
        info "使用本地二进制: /root/esa-router/esa-router-v1.5"
        cp "/root/esa-router/esa-router-v1.5" "$BINARY_PATH.new"
    elif [ -f "$BINARY_PATH" ] && [ "$(stat -c%s "$BINARY_PATH" 2>/dev/null)" -gt 1000000 ]; then
        info "使用现有二进制: $BINARY_PATH"
        cp "$BINARY_PATH" "$BINARY_PATH.new"
    else
        info "下载 ESA Router v$VERSION..."
        local url="$GITHUB/$REPO/releases/download/v$VERSION/$BINARY_NAME"
        curl -sL "$url" -o "$BINARY_PATH.new" || {
            error "下载失败，请手动上传二进制文件"
        }
    fi

    # 验证文件
    if [ ! -s "$BINARY_PATH.new" ]; then
        error "下载的文件为空"
    fi

    chmod +x "$BINARY_PATH.new"
    mv "$BINARY_PATH.new" "$BINARY_PATH"

    info "二进制已安装: $(ls -lh "$BINARY_PATH" | awk '{print $5}')"
}

create_config() {
    if [ -f "$CONFIG_PATH" ]; then
        warn "配置文件已存在: $CONFIG_PATH"
        info "当前配置:"
        cat "$CONFIG_PATH"
        echo ""
        read -r -p "是否重新配置? [y/N]: " reconfig
        if [[ ! "$reconfig" =~ ^[Yy]$ ]]; then
            info "跳过配置"
            return
        fi
    fi

    info "配置 ESA Router..."

    # 询问监听端口
    read -r -p "监听端口 [7826]: " port_input
    listen_port="${port_input:-7826}"

    # 询问路由模式
    echo ""
    echo "请选择路由模式:"
    echo "  1) 通配符模式 (/node-* 匹配所有端口)"
    echo "  2) 范围模式 (/node-20001-30000 匹配指定范围)"
    echo "  3) 静态模式 (/node-us -> 指定端口)"
    echo ""
    read -r -p "选择 [1-3]: " route_mode

    case $route_mode in
        1)
            route_config='"/node-*" = "127.0.0.1:<port>"'
            ;;
        2)
            read -r -p "端口范围 (如 20001-30000) [20001-40000]: " range_input
            range="${range_input:-20001-40000}"
            route_config="\"/node-$range\" = \"127.0.0.1:<port>\""
            ;;
        3)
            info "静态模式示例: /node-us = 127.0.0.1:30927"
            read -r -p "请输入路由规则 (如 '/node-us' = '127.0.0.1:30927'): " static_rule
            if [ -z "$static_rule" ]; then
                static_rule='"/node-us" = "127.0.0.1:30927"'
            fi
            route_config="$static_rule"
            ;;
        *)
            route_config='"/node-*" = "127.0.0.1:<port>"'
            warn "无效选择，使用默认通配符模式"
            ;;
    esac

    info "创建配置文件..."
    cat > "$CONFIG_PATH" << EOF
# ESA Router v1.5 配置
listen_port = $listen_port

[routers]
$route_config
EOF
    info "配置已创建: $CONFIG_PATH"
}

install_service() {
    info "安装 systemd 服务..."
    cat > /etc/systemd/system/$SERVICE_NAME.service << 'EOF'
[Unit]
Description=ESA Router - WebSocket Path Router
After=network.target

[Service]
Type=simple
ExecStart=$SYMLINK_PATH $CONFIG_PATH
Restart=always
RestartSec=3
StandardOutput=journal
StandardError=journal
SyslogIdentifier=$SERVICE_NAME

# 安全加固
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=yes
ReadWritePaths=$CONFIG_DIR

[Install]
WantedBy=multi-user.target
EOF
    
    systemctl daemon-reload
    info "服务已安装"
}

start_service() {
    info "启动服务..."
    systemctl enable "$SERVICE_NAME"
    systemctl start "$SERVICE_NAME"
    sleep 2
    
    if systemctl is-active --quiet "$SERVICE_NAME"; then
        info "服务启动成功"
        systemctl status "$SERVICE_NAME" --no-pager | head -8
    else
        error "服务启动失败"
    fi
}

show_usage() {
    echo ""
    echo "ESA Router v$VERSION 安装完成!"
    echo ""
    echo "配置:"
    echo "  路径: $CONFIG_PATH"
    echo ""
    echo "服务:"
    echo "  状态: systemctl status $SERVICE_NAME"
    echo "  启动: systemctl start $SERVICE_NAME"
    echo "  停止: systemctl stop $SERVICE_NAME"
    echo "  重启: systemctl restart $SERVICE_NAME"
    echo "  重载: kill -1 \$(pgrep $SERVICE_NAME)"
    echo ""
    echo "路由示例:"
    echo "  /node-21581 → 127.0.0.1:21581 (通配符)"
    echo "  /node-25000 → 127.0.0.1:25000 (范围内)"
    echo "  /node-30927 → 被拒绝 (超出范围)"
    echo ""
}

update_mode() {
    echo ""
    echo "选择更新模式:"
    echo "  1) 完整安装 (更新二进制+重新配置)"
    echo "  2) 仅更新二进制"
    echo "  3) 检查更新"
    echo "  4) 退出"
    echo ""

    read -r -p "请选择 [1-4]: " choice
    case $choice in
        1)
            download_binary
            create_config
            systemctl restart "$SERVICE_NAME" 2>/dev/null || nohup /usr/local/bin/esa-router /etc/esa-router/config.toml > /var/log/esa-router.log 2>&1 &
            info "二进制和配置已更新，服务已重启"
            ;;
        2) update_binary_only ;;
        3) check_update ;;
        4) echo "退出"; exit 0 ;;
        *) error "无效选择" ;;
    esac
}

install_full() {
    download_binary
    create_directories
    create_config
    install_service
    start_service
    show_usage
}

update_binary_only() {
    download_binary
    systemctl restart "$SERVICE_NAME"
    info "二进制已更新，服务已重启"
}

check_update() {
    info "检查最新版本..."
    local latest_url="$GITHUB/$REPO/releases/latest/download/$BINARY_NAME"
    local latest_hash=$(curl -sL "$latest_url" | md5sum | awk '{print $1}')
    local current_hash=$(md5sum "$BINARY_PATH" 2>/dev/null | awk '{print $1}' || echo "未安装")
    
    echo ""
    echo "最新版本: v$VERSION"
    echo "当前版本: $(systemctl show $SERVICE_NAME --property=ExecStart --value 2>/dev/null || echo '未运行')"
    echo "MD5 匹配: $([ "$latest_hash" = "$current_hash" ] && echo '是' || echo '否')"
}

# 交互模式检测
if [ -t 0 ]; then
    echo "==================================="
    echo "  ESA Router v$VERSION 安装脚本"
    echo "==================================="
    echo ""
    echo "1) 全新安装"
    echo "2) 更新安装"
    echo "3) 退出"
    echo ""
    
    read -r -p "请选择 [1-3]: " choice
    
    case $choice in
        1)
            check_root
            check_os
            check_arch
            install_dependencies
            create_directories
            install_full
            ;;
        2)
            check_root
            check_os
            check_arch
            update_mode
            ;;
        3)
            echo "退出"
            exit 0
            ;;
        *)
            error "无效选择"
            ;;
    esac
else
    # 非交互模式（管道安装）
    check_root
    check_os
    check_arch
    install_dependencies
    create_directories
    install_full
fi
