#!/bin/bash
# ESA Router 安装脚本 v1.3
# 用法: curl -sSL https://raw.githubusercontent.com/loensos/esa-router/main/deploy.sh | bash

set -e

VERSION="1.3"
REPO="loensos/esa-router"
GITHUB="https://github.com"
INSTALL_DIR="/opt/esa-router"
CONFIG_DIR="/etc/esa-router"
SERVICE_NAME="esa-router"

BINARY_NAME="esa-router-linux-amd64"
BINARY_PATH="$INSTALL_DIR/$BINARY_NAME"
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
    info "下载 ESA Router v$VERSION..."
    local url="$GITHUB/$REPO/releases/download/v$VERSION/$BINARY_NAME"
    
    curl -sL "$url" -o "$BINARY_PATH.new" || error "下载失败"
    
    # 验证文件
    if [ ! -s "$BINARY_PATH.new" ]; then
        error "下载的文件为空"
    fi
    
    chmod +x "$BINARY_PATH.new"
    mv "$BINARY_PATH.new" "$BINARY_PATH"
    ln -sf "$BINARY_PATH" "$SYMLINK_PATH"
    
    info "二进制已安装: $(ls -lh "$BINARY_PATH" | awk '{print $5}')"
}

create_config() {
    if [ -f "$CONFIG_PATH" ]; then
        warn "配置文件已存在，跳过创建: $CONFIG_PATH"
        info "当前配置:"
        cat "$CONFIG_PATH"
    else
        info "创建默认配置 (v1.3 - 范围匹配)..."
        cat > "$CONFIG_PATH" << 'EOF'
# ESA Router v1.3 配置
# 监听端口
listen_port = 7826

[routers]
# 通配符路由 - 匹配所有 /node-端口 路径
"/node-*" = "127.0.0.1:<port>"
# 范围路由 - 只接受 20001-30000 端口（优先于通配符）
"/node-20001-30000" = "127.0.0.1:<port>"
EOF
        info "配置已创建: $CONFIG_PATH"
    fi
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
    echo "  1) 完整安装 (更新二进制+配置)"
    echo "  2) 仅更新二进制"
    echo "  3) 检查更新"
    echo "  4) 退出"
    echo ""
    
    read -r -p "请选择 [1-4]: " choice
    case $choice in
        1) install_full ;;
        2) update_binary_only ;;
        3) check_update ;;
        4) echo "退出"; exit 0 ;;
        *) error "无效选择" ;;
    esac
}

install_full() {
    download_binary
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
