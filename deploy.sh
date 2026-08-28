#!/bin/bash
# ESA Router 安装脚本 v1.5
# 用法: curl -sSL https://raw.githubusercontent.com/loensos/esa-router/main/deploy.sh -o deploy.sh && bash deploy.sh

VERSION="1.5.2"
REPO="loensos/esa-router"
GITHUB="https://github.com"
GITHUB_API="https://api.github.com"
INSTALL_DIR="/usr/local/bin"
CONFIG_DIR="/etc/esa-router"
SERVICE_NAME="esa-router"

BINARY_NAME="esa-router-v1.5-linux-amd64"
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
    info "从 GitHub 下载最新版本..."
    local api_url="$GITHUB_API/repos/$REPO/releases/latest"
    local remote_url=$(curl -sL "$api_url" | grep -o '"browser_download_url": "[^"]*' | grep "$BINARY_NAME" | cut -d'"' -f4 | head -1)

    if [ -z "$remote_url" ]; then
        # Fallback to versioned URL
        remote_url="$GITHUB/$REPO/releases/download/v$VERSION/$BINARY_NAME"
        warn "API 获取失败，使用版本化 URL: $remote_url"
    fi

    # 强制从 GitHub 下载到临时文件
    local tmp_bin="/tmp/esa-router-latest"
    rm -f "$tmp_bin"
    if ! curl -sL "$remote_url" -o "$tmp_bin"; then
        error "下载失败: $remote_url"
    fi

    if [ ! -s "$tmp_bin" ]; then
        error "下载的文件为空"
    fi

    local remote_size=$(stat -c%s "$tmp_bin" 2>/dev/null)
    if [ "$remote_size" -lt 1000000 ]; then
        error "下载文件太小 ($remote_size 字节)，可能不是有效 binary"
    fi

    # 移动到安装位置
    chmod +x "$tmp_bin"
    mv "$tmp_bin" "$BINARY_PATH.new"
    mv "$BINARY_PATH.new" "$BINARY_PATH"

    info "已从 GitHub 下载: v$VERSION ($(($remote_size / 1024 / 1024))MB)"
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
    echo "  2) 范围模式 (指定端口范围，如 /node-20001-50000)"
    echo "  3) 静态模式 (/node-us -> 指定端口)"
    echo ""
    read -r -p "选择 [1-3]: " route_mode

    case $route_mode in
        1)
            route_config='{ path = "/node-*", backend = "127.0.0.1:<port>" }'
            ;;
        2)
            read -r -p "端口范围起始 (如 20001) [20001]: " min_port_input
            min_port="${min_port_input:-20001}"
            read -r -p "端口范围结束 (如 50000) [50000]: " max_port_input
            max_port="${max_port_input:-50000}"
            route_config="{ path = \"/node-\", backend = \"127.0.0.1:<port>\", min_port = $min_port, max_port = $max_port }"
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
            route_config='{ path = "/node-*", backend = "127.0.0.1:<port>" }'
            warn "无效选择，使用默认通配符模式"
            ;;
    esac

    info "创建配置文件..."
    cat > "$CONFIG_PATH" << EOF
# ESA Router v1.5 配置
listen_port = $listen_port

[[routers]]
  $route_config
EOF
    info "配置已创建: $CONFIG_PATH"
}

install_service() {
    info "安装 systemd 服务..."
    cat > /etc/systemd/system/$SERVICE_NAME.service << EOF
[Unit]
Description=ESA Router - WebSocket Path Router
After=network.target

[Service]
Type=simple
ExecStart=$INSTALL_DIR/esa-router /etc/esa-router/config.toml
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

update_binary_only() {
    download_binary
    systemctl restart "$SERVICE_NAME"
    info "二进制已更新，服务已重启"
}

uninstall() {
    check_root
    echo ""
    warn "即将卸载 ESA Router v$VERSION"
    warn "这将删除: 二进制文件、配置目录、systemd 服务"
    echo ""
    read -r -p "确认卸载? [y/N]: " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        info "取消卸载"
        return
    fi

    # Stop and disable service
    if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
        info "停止服务..."
        systemctl stop "$SERVICE_NAME"
    fi
    if systemctl is-enabled --quiet "$SERVICE_NAME" 2>/dev/null; then
        info "禁用服务..."
        systemctl disable "$SERVICE_NAME"
    fi

    # Remove systemd service file
    if [ -f /etc/systemd/system/$SERVICE_NAME.service ]; then
        info "删除 systemd 服务文件..."
        rm -f /etc/systemd/system/$SERVICE_NAME.service
        systemctl daemon-reload
    fi

    # Backup config
    if [ -f "$CONFIG_PATH" ]; then
        local backup_path="${CONFIG_PATH}.backup.$(date +%Y%m%d%H%M%S)"
        info "备份配置到: $backup_path"
        cp "$CONFIG_PATH" "$backup_path"
    fi

    # Remove files
    if [ -f "$BINARY_PATH" ]; then
        info "删除二进制: $BINARY_PATH"
        rm -f "$BINARY_PATH"
    fi
    if [ -d "$CONFIG_DIR" ]; then
        info "删除配置目录: $CONFIG_DIR"
        rm -rf "$CONFIG_DIR"
    fi

    echo ""
    info "卸载完成！"
    info "配置已备份到 ${CONFIG_PATH}.backup.*"
}

check_update() {
    info "检查最新版本..."
    local api_url="$GITHUB_API/repos/$REPO/releases/latest"
    local download_url=$(curl -sL "$api_url" | grep -o '"browser_download_url": "[^"]*' | grep "$BINARY_NAME" | cut -d'"' -f4 | head -1)
    
    if [ -z "$download_url" ]; then
        download_url="$GITHUB/$REPO/releases/download/v$VERSION/$BINARY_NAME"
    fi
    
    local latest_hash=$(curl -sL "$download_url" | md5sum | awk '{print $1}')
    local current_hash=$(md5sum "$BINARY_PATH" 2>/dev/null | awk '{print $1}' || echo "未安装")
    
    echo ""
    echo "最新版本: v$VERSION"
    echo "当前版本: $(systemctl show $SERVICE_NAME --property=ExecStart --value 2>/dev/null || echo '未运行')"
    echo "MD5 匹配: $([ "$latest_hash" = "$current_hash" ] && echo '是' || echo '否')"
}

configure_params() {
    echo ""
    info "参数设置"
    echo ""
    info "当前配置:"
    if [ -f "$CONFIG_PATH" ]; then
        cat "$CONFIG_PATH"
    else
        echo "  (无配置文件)"
    fi
    echo ""

    read -r -p "是否修改配置? [y/N]: " modify_config
    if [[ ! "$modify_config" =~ ^[Yy]$ ]]; then
        info "跳过配置"
        return
    fi

    # 修改监听端口
    local current_port=$(grep 'listen_port' "$CONFIG_PATH" 2>/dev/null | grep -oE '[0-9]+' || echo "7826")
    read -r -p "监听端口 [$current_port]: " port_input
    listen_port="${port_input:-$current_port}"

    # 加载现有路由
        local -a routes=()
        local route_count=0
        if [ -f "$CONFIG_PATH" ]; then
            # 读取路由 - 支持新旧两种格式
            # 旧格式: "/node-xxx" = "127.0.0.1:port"
            # 新格式: { path = "/node-xxx", backend = "127.0.0.1:port" }
            #         { path = "/node-xxx", backend = "127.0.0.1:<port>", min_port = N, max_port = M }
            while IFS= read -r line; do
                # 跳过空行和注释
                [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
                # 跳过 section 标记
                [[ "$line" =~ ^[[:space:]]*\[.*\] ]] && continue
                # 跳过 [[routers]] 数组标记
                [[ "$line" =~ ^[[:space:]]*\[\[.*\]\] ]] && continue

                # 匹配新格式: { path = ..., backend = ... }
                if [[ "$line" =~ ^[[:space:]]*\{[[:space:]]*path[[:space:]]*= ]]; then
                    routes+=("$line")
                    route_count=$((route_count + 1))
                    continue
                fi

                # 匹配旧格式: "path" = "backend"
                if [[ "$line" =~ ^[[:space:]]*\"[^\"]+\"[[:space:]]*=[[:space:]]*\"[^\"]+\" ]]; then
                    # 转换为新格式
                    local path_part=$(echo "$line" | sed -E 's|^[[:space:]]*"([^"]+)"[[:space:]]*=[[:space:]]*"([^"]+)".*|{ path = "\1", backend = "\2" }|')
                    routes+=("$path_part")
                    route_count=$((route_count + 1))
                fi
            done < "$CONFIG_PATH"
        fi

            while true; do
                echo ""
                echo "路由列表 ($route_count 条):"
                if [ $route_count -eq 0 ]; then
                    echo "  (空)"
                else
                    for i in "${!routes[@]}"; do
                        echo "  $((i+1)). ${routes[$i]}"
                    done
                fi
                echo ""
                echo "  1) 添加通配符路由 (/node-* 匹配所有端口)"
                echo "  2) 添加范围路由 (指定端口范围)"
                echo "  3) 添加静态路由 (/node-us -> 指定端口)"
                echo "  4) 删除路由"
                echo "  5) 完成并保存"
                echo ""
                read -r -p "选择 [1-5]: " route_action

                case $route_action in
                    1)
                        routes+=('{ path = "/node-*", backend = "127.0.0.1:<port>" }')
                        route_count=$((route_count + 1))
                        info "已添加: /node-*"
                        ;;
                    2)
                        read -r -p "端口范围起始 (如 20001) [20001]: " min_port_input
                        min_port="${min_port_input:-20001}"
                        read -r -p "端口范围结束 (如 50000) [50000]: " max_port_input
                        max_port="${max_port_input:-50000}"
                        routes+=("{ path = \"/node-\", backend = \"127.0.0.1:<port>\", min_port = $min_port, max_port = $max_port }")
                        route_count=$((route_count + 1))
                        info "已添加: /node-$min_port-$max_port"
                        ;;
                    3)
                        info "静态模式示例: /node-us = 127.0.0.1:30927"
                        read -r -p "请输入路由规则 (如 '/node-us' = '127.0.0.1:30927'): " static_rule
                        if [ -n "$static_rule" ]; then
                            # 简单处理：自动添加双引号
                            static_rule=$(echo "$static_rule" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
                            # 如果没有引号，自动添加
                            if [[ "$static_rule" != *\"* ]]; then
                                # 格式: /path = ip:port
                                route_entry=$(echo "$static_rule" | sed 's|^[[:space:]]*\([^=]*[^[:space:]]\)[[:space:]]*=[[:space:]]*\(.*\)$|"\1" = "\2"|')
                            else
                                route_entry="$static_rule"
                            fi
                            routes+=("$route_entry")
                            route_count=$((route_count + 1))
                            info "已添加: $route_entry"
                        fi
                        ;;
            4)
                if [ $route_count -eq 0 ]; then
                    warn "没有可删除的路由"
                    continue
                fi
                echo ""
                read -r -p "删除第几条 [1-$route_count]: " del_idx
                if [[ "$del_idx" =~ ^[0-9]+$ ]] && [ "$del_idx" -ge 1 ] && [ "$del_idx" -le "$route_count" ]; then
                    unset 'routes[$((del_idx-1))]'
                    routes=("${routes[@]}")
                    route_count=$((route_count - 1))
                    info "已删除路由 #$del_idx"
                fi
                ;;
            5)
                break
                ;;
            *)
                warn "无效选择"
                ;;
        esac
    done

    # 生成配置文件
    info "创建配置文件..."
    {
        echo "# ESA Router v1.5.2 配置"
        echo "listen_port = $listen_port"
        echo ""
        echo "[[routers]]"
        for route in "${routes[@]}"; do
            echo "$route"
        done
    } > "$CONFIG_PATH"
    info "配置已更新: $CONFIG_PATH"

    # 重启服务
    systemctl restart "$SERVICE_NAME" 2>/dev/null || nohup /usr/local/bin/esa-router /etc/esa-router/config.toml > /var/log/esa-router.log 2>&1 &
    sleep 1
    info "服务已重启"
}

# 检测管道模式
if [ ! -t 0 ]; then
    echo "==================================="
    echo "  ESA Router v$VERSION 管理脚本"
    echo "==================================="
    echo ""
    echo "警告: 检测到管道模式，不支持交互式操作"
    echo ""
    echo "请使用以下方法:"
    echo "  curl -sSL https://raw.githubusercontent.com/loensos/esa-router/main/deploy.sh -o deploy.sh"
    echo "  bash deploy.sh"
    echo ""
    exit 1
fi

echo "==================================="
echo "  ESA Router v$VERSION 管理脚本"
echo "==================================="
echo ""
echo "1) 全新安装"
echo "2) 更新二进制"
echo "3) 设置参数"
echo "4) 检查更新"
echo "5) 卸载"
echo "6) 退出"
echo ""

read -r -p "请选择 [1-6]: " choice

case $choice in
    1)
        check_root
        check_os
        check_arch
        install_dependencies
        create_directories
        download_binary
        create_config
        install_service
        start_service
        show_usage
        ;;
    2)
        check_root
        check_os
        check_arch
        update_binary_only
        ;;
    3)
        check_root
        configure_params
        ;;
    4)
        check_root
        check_update
        ;;
    5)
        uninstall
        ;;
    6)
        echo "退出"
        exit 0
        ;;
    *)
        error "无效选择"
        ;;
esac