#!/bin/bash
# sing-box 手搓部署脚本（稳定优先版）—— VLESS + TCP + Reality + xtls-rprx-vision
# 适配：Debian 12/13、Ubuntu 22.04/24.04
# 用法：sudo bash install.sh
# 卸载：sudo bash install.sh --uninstall 或安装后运行 sb uninstall

set -euo pipefail

# ===== 需要你自定义的部分 =====

REALITY_UUID=""                      # 留空则自动生成；已有想固定的 UUID 可填在这里
NODE_NAME="my-singbox-node"          # 分享链接里显示的节点名，随便起

# 端口与 SNI 改为运行时手动输入，无需在此处修改

# ===== 自定义部分结束，以下无需修改 =====

CONFIG_DIR="/etc/sing-box"
CONFIG_FILE="$CONFIG_DIR/config.json"
NODE_INFO_FILE="$CONFIG_DIR/node_info.conf"
BACKUP_DIR="$CONFIG_DIR/backups"
SERVICE_OVERRIDE_DIR="/etc/systemd/system/sing-box.service.d"
LOG_PREFIX="[sing-box-setup]"

err() { echo "$LOG_PREFIX 错误: $1" >&2; exit 1; }
info() { echo "$LOG_PREFIX $1"; }

# ---------- 彻底卸载模块 ----------
uninstall_singbox() {
    [ "$(id -u)" -eq 0 ] || err "请用 root 权限执行卸载（sudo bash $0 --uninstall）"
    info "正在停止并清理 sing-box 服务..."
    systemctl stop sing-box 2>/dev/null || true
    systemctl disable sing-box 2>/dev/null || true

    info "清理 apt 安装包与官方软件源..."
    if command -v apt >/dev/null 2>&1; then
        apt purge -y sing-box 2>/dev/null || true
        apt autoremove -y 2>/dev/null || true
    fi

    rm -f /etc/apt/sources.list.d/sagernet.sources /etc/apt/sources.list.d/sagernet.list
    rm -f /etc/apt/keyrings/sagernet.asc /usr/share/keyrings/sagernet.gpg

    info "清理配置文件、备份及 systemd 覆盖项..."
    rm -rf "$CONFIG_DIR"
    rm -rf "$SERVICE_OVERRIDE_DIR"
    rm -f /usr/local/bin/sb

    systemctl daemon-reload || true
    echo ""
    echo "=================================================="
    echo "       sing-box 及相关配置已彻底卸载并清理完成！   "
    echo "=================================================="
    exit 0
}

# 检查是否传入卸载参数
if [ "${1:-}" = "uninstall" ] || [ "${1:-}" = "--uninstall" ] || [ "${1:-}" = "-u" ]; then
    uninstall_singbox
fi

# ---------- 交互式输入：端口与 SNI ----------

if [ ! -t 0 ] && [ -e /dev/tty ]; then
    read -rp "请输入 Reality 监听端口 [默认 443]: " REALITY_PORT_INPUT < /dev/tty || true
    read -rp "请输入伪装目标域名 SNI [默认 www.apple.com]: " REALITY_SNI_INPUT < /dev/tty || true
else
    read -rp "请输入 Reality 监听端口 [默认 443]: " REALITY_PORT_INPUT || true
    read -rp "请输入伪装目标域名 SNI [默认 www.apple.com]: " REALITY_SNI_INPUT || true
fi

REALITY_PORT="${REALITY_PORT_INPUT:-443}"

if ! [[ "$REALITY_PORT" =~ ^[0-9]+$ ]] || [ "$REALITY_PORT" -lt 1 ] || [ "$REALITY_PORT" -gt 65535 ]; then
    err "端口输入不合法: $REALITY_PORT（需为 1-65535 之间的数字）"
fi

REALITY_SNI="${REALITY_SNI_INPUT:-www.apple.com}"

if [ -z "$REALITY_SNI" ]; then
    err "SNI 不能为空"
fi

info "已确认: 端口=${REALITY_PORT}, SNI=${REALITY_SNI}"

# ---------- 0. 基础检查 ----------

[ "$(id -u)" -eq 0 ] || err "请用 root 权限运行（sudo bash $0）"

if [ ! -r /etc/os-release ]; then
    err "找不到 /etc/os-release，无法识别系统版本"
fi
# shellcheck disable=SC1091
. /etc/os-release

case "$ID" in
    debian)
        case "$VERSION_ID" in
            12|13) ;;
            *) err "检测到 Debian $VERSION_ID，本脚本仅测试过 Debian 12/13，其他版本请手动确认兼容性" ;;
        esac
        ;;
    ubuntu)
        case "$VERSION_ID" in
            22.04|24.04) ;;
            *) err "检测到 Ubuntu $VERSION_ID，本脚本仅测试过 Ubuntu 22.04/24.04，其他版本请手动确认兼容性" ;;
        esac
        ;;
    *)
        err "不支持的系统: $ID（本脚本仅适配 Debian 12/13 与 Ubuntu 22.04/24.04）"
        ;;
esac
info "系统检测通过: $PRETTY_NAME"

# 端口占用检查（排除 sing-box 自身）
if command -v ss >/dev/null 2>&1; then
    LISTENER_PID=""
    set +e
    LISTENER_PID=$(ss -tlnp 2>/dev/null | awk -v p=":${REALITY_PORT}\$" '$4 ~ p {print}' | grep -oP 'pid=\K[0-9]+' | head -n1)
    set -e
    if [ -n "${LISTENER_PID:-}" ]; then
        LISTENER_CMD=$(readlink -f "/proc/${LISTENER_PID}/exe" 2>/dev/null || echo "")
        if [[ "$LISTENER_CMD" == *"sing-box"* ]]; then
            info "端口 ${REALITY_PORT} 当前被 sing-box 自身占用（PID ${LISTENER_PID}），视为更新配置，继续执行"
        else
            err "端口 ${REALITY_PORT} 已被其他进程占用（PID ${LISTENER_PID}: ${LISTENER_CMD:-未知}），请先释放该端口或更换端口"
        fi
    fi
fi

# ---------- 1. 安装依赖与 sing-box ----------

info "更新软件源并安装依赖"
apt update -y || err "apt update 失败，请检查网络或软件源配置"
apt install -y curl openssl ca-certificates jq || err "基础依赖安装失败"

if ! command -v sing-box >/dev/null 2>&1; then
    info "添加 sing-box 官方 apt 源（deb822 格式）"
    mkdir -p /etc/apt/keyrings
    curl -fsSL https://sing-box.app/gpg.key -o /etc/apt/keyrings/sagernet.asc \
        || err "下载 sing-box 签名公钥失败，请检查网络"
    chmod a+r /etc/apt/keyrings/sagernet.asc

    rm -f /etc/apt/sources.list.d/sagernet.list /usr/share/keyrings/sagernet.gpg

    cat > /etc/apt/sources.list.d/sagernet.sources <<'EOF'
Types: deb
URIs: https://deb.sagernet.org/
Suites: *
Components: *
Enabled: yes
Signed-By: /etc/apt/keyrings/sagernet.asc
EOF

    apt update -y || err "添加 sing-box 源后 apt update 失败"
    apt install -y sing-box || err "sing-box 安装失败，请检查上方 apt 输出"
else
    info "sing-box 已安装，跳过安装步骤（如需升级请手动执行 apt upgrade sing-box）"
fi

command -v sing-box >/dev/null 2>&1 || err "sing-box 安装完成但未在 PATH 中找到"
SB_VERSION=$(sing-box version | head -n1)
info "已安装: $SB_VERSION"

mkdir -p "$CONFIG_DIR" "$BACKUP_DIR"
chmod 700 "$CONFIG_DIR" "$BACKUP_DIR"

# ---------- 2. 生成密钥材料 ----------

info "生成 UUID 与 Reality 密钥对"
if [ -z "$REALITY_UUID" ]; then
    REALITY_UUID=$(sing-box generate uuid) || err "生成 UUID 失败"
fi

KEYPAIR=$(sing-box generate reality-keypair) || err "生成 Reality 密钥对失败"
REALITY_PRIVATE_KEY=$(echo "$KEYPAIR" | awk -F': *' '/PrivateKey/ {print $2}' | tr -d ' \t\r\n')
REALITY_PUBLIC_KEY=$(echo "$KEYPAIR" | awk -F': *' '/PublicKey/ {print $2}' | tr -d ' \t\r\n')

[ -n "$REALITY_PRIVATE_KEY" ] && [ -n "$REALITY_PUBLIC_KEY" ] || err "Reality 密钥对解析失败"

info "生成随机 Reality short_id"
REALITY_SHORT_ID=$(sing-box generate rand --hex 8 | tr -d ' \t\r\n') || err "生成 short_id 失败"
[ -n "$REALITY_SHORT_ID" ] || err "short_id 生成结果为空"

# ---------- 3. 写配置（先备份旧配置） ----------

SERVICE_RUN_USER=$(systemctl show sing-box.service -p User --value 2>/dev/null || echo "")
if [ -n "$SERVICE_RUN_USER" ] && [ "$SERVICE_RUN_USER" != "root" ] && id "$SERVICE_RUN_USER" >/dev/null 2>&1; then
    CONFIG_FILE_OWNER="root:${SERVICE_RUN_USER}"
    CONFIG_FILE_MODE="640"
    info "检测到 sing-box 服务以非 root 账户 ${SERVICE_RUN_USER} 运行，配置文件将设为 ${CONFIG_FILE_OWNER} ${CONFIG_FILE_MODE}"
else
    CONFIG_FILE_OWNER="root:root"
    CONFIG_FILE_MODE="600"
fi

if [ -f "$CONFIG_FILE" ]; then
    BACKUP_FILE="$BACKUP_DIR/config.json.$(date +%Y%m%d-%H%M%S).bak"
    cp "$CONFIG_FILE" "$BACKUP_FILE" || err "旧配置备份失败"
    chown root:root "$BACKUP_FILE"
    chmod 600 "$BACKUP_FILE"
    info "已备份旧配置到 $BACKUP_FILE"
fi

info "生成新配置"
TMP_CONFIG=$(mktemp)
trap 'rm -f "$TMP_CONFIG"' EXIT INT TERM

cat > "$TMP_CONFIG" <<EOF
{
  "log": {
    "level": "info",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-reality-in",
      "listen": "::",
      "listen_port": ${REALITY_PORT},
      "users": [
        { "uuid": "${REALITY_UUID}", "flow": "xtls-rprx-vision" }
      ],
      "tls": {
        "enabled": true,
        "server_name": "${REALITY_SNI}",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "${REALITY_SNI}",
            "server_port": 443
          },
          "private_key": "${REALITY_PRIVATE_KEY}",
          "short_id": ["${REALITY_SHORT_ID}"]
        }
      }
    }
  ],
  "outbounds": [
    { "type": "direct", "tag": "direct" }
  ]
}
EOF

# ---------- 4. 启动前校验，校验通过才落地替换配置 ----------

info "校验新配置语法"
sing-box check -c "$TMP_CONFIG" || {
    rm -f "$TMP_CONFIG"
    err "新配置校验未通过，已保留原配置未做替换"
}

mv "$TMP_CONFIG" "$CONFIG_FILE"
chown "$CONFIG_FILE_OWNER" "$CONFIG_FILE"
chmod "$CONFIG_FILE_MODE" "$CONFIG_FILE"
info "配置校验通过并已写入 $CONFIG_FILE"

# 保存公钥与节点元数据（供快捷命令随时查看）
cat > "$NODE_INFO_FILE" <<EOF
REALITY_UUID="${REALITY_UUID}"
REALITY_PORT="${REALITY_PORT}"
REALITY_SNI="${REALITY_SNI}"
REALITY_PUBLIC_KEY="${REALITY_PUBLIC_KEY}"
REALITY_SHORT_ID="${REALITY_SHORT_ID}"
NODE_NAME="${NODE_NAME}"
EOF
chmod 600 "$NODE_INFO_FILE"

# 清理超过 10 份的旧备份
BACKUP_COUNT=$(find "$BACKUP_DIR" -name 'config.json.*.bak' | wc -l)
if [ "$BACKUP_COUNT" -gt 10 ]; then
    find "$BACKUP_DIR" -name 'config.json.*.bak' -printf '%T@ %p\n' \
        | sort -n | head -n -10 | awk '{print $2}' | xargs -r rm -f
    info "已清理旧备份，仅保留最近 10 份"
fi

# ---------- 5. systemd：开机自启 + 异常退出自动重启 + 权限绑定 ----------

info "配置 systemd 自动重启策略与端口绑定权限"
mkdir -p "$SERVICE_OVERRIDE_DIR"
cat > "$SERVICE_OVERRIDE_DIR/override.conf" <<'EOF'
[Unit]
StartLimitIntervalSec=300
StartLimitBurst=10

[Service]
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
Restart=on-failure
RestartSec=5s
EOF

systemctl daemon-reload || err "systemd daemon-reload 失败"
systemctl enable sing-box || err "设置开机自启失败"

info "重启 sing-box 服务"
systemctl restart sing-box || {
    echo "$LOG_PREFIX 服务启动失败，最近日志：" >&2
    journalctl -u sing-box -n 30 --no-pager >&2
    err "sing-box 启动失败，请根据上方日志排查"
}

sleep 2
if ! systemctl is-active --quiet sing-box; then
    echo "$LOG_PREFIX 服务未处于 active 状态，最近日志：" >&2
    journalctl -u sing-box -n 30 --no-pager >&2
    err "sing-box 服务启动后未能保持运行"
fi

info "sing-box 服务运行正常"

# ---------- 6. 创建快捷命令 /usr/local/bin/sb ----------

cat > /usr/local/bin/sb <<'EOF'
#!/bin/bash
set -e

INFO_FILE="/etc/sing-box/node_info.conf"
CONFIG_FILE="/etc/sing-box/config.json"

show_info() {
    if [ ! -f "$INFO_FILE" ]; then
        echo "未找到节点元数据，请确认是否已成功安装 sing-box。"
        exit 1
    fi
    . "$INFO_FILE"

    SERVER_IP=$(curl -s -4 --max-time 4 https://api.ipify.org || echo "")
    if [ -z "$SERVER_IP" ]; then
        SERVER_IP=$(curl -s -6 --max-time 4 https://api64.ipify.org || echo "")
    fi
    if [ -z "$SERVER_IP" ]; then
        SERVER_IP="<获取失败，请手动填入服务器公网IP>"
    fi

    SERVER_IP_FOR_LINK="$SERVER_IP"
    if [[ "$SERVER_IP" == *:* ]]; then
        SERVER_IP_FOR_LINK="[${SERVER_IP}]"
    fi

    NODE_NAME_ENCODED="$NODE_NAME"
    NODE_NAME_ENCODED="${NODE_NAME_ENCODED//%/%25}"
    NODE_NAME_ENCODED="${NODE_NAME_ENCODED// /%20}"
    NODE_NAME_ENCODED="${NODE_NAME_ENCODED//&/%26}"
    NODE_NAME_ENCODED="${NODE_NAME_ENCODED//#/%23}"
    NODE_NAME_ENCODED="${NODE_NAME_ENCODED//\?/%3F}"
    NODE_NAME_ENCODED="${NODE_NAME_ENCODED//+/%2B}"

    VLESS_LINK="vless://${REALITY_UUID}@${SERVER_IP_FOR_LINK}:${REALITY_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_SNI}&fp=chrome&pbk=${REALITY_PUBLIC_KEY}&sid=${REALITY_SHORT_ID}&type=tcp#${NODE_NAME_ENCODED}"

    echo ""
    echo "================ sing-box 节点配置 ================"
    echo "协议:        VLESS + TCP + Reality + xtls-rprx-vision"
    echo "服务器 IP:   ${SERVER_IP}"
    echo "端口:        ${REALITY_PORT}"
    echo "UUID:        ${REALITY_UUID}"
    echo "Flow:        xtls-rprx-vision"
    echo "SNI:         ${REALITY_SNI}"
    echo "PublicKey:   ${REALITY_PUBLIC_KEY}"
    echo "ShortId:     ${REALITY_SHORT_ID}"
    echo "指纹(fp):    chrome"
    echo ""
    echo "分享链接:"
    echo "${VLESS_LINK}"
    echo "=================================================="
    echo "常用命令:    sb (查看配置) | sb status | sb log | sb restart | sb uninstall"
    echo "=================================================="
}

case "${1:-info}" in
    info|"")
        show_info
        ;;
    status)
        systemctl status sing-box
        ;;
    log)
        journalctl -u sing-box -f
        ;;
    restart)
        systemctl restart sing-box
        echo "sing-box 服务已重启"
        ;;
    uninstall)
        read -rp "确定要彻底卸载 sing-box 及其所有配置吗？[y/N]: " CONFIRM
        if [[ "$CONFIRM" =~ ^[yY]$ ]]; then
            systemctl stop sing-box 2>/dev/null || true
            systemctl disable sing-box 2>/dev/null || true
            apt purge -y sing-box 2>/dev/null || true
            apt autoremove -y 2>/dev/null || true
            rm -rf /etc/sing-box /etc/systemd/system/sing-box.service.d /etc/apt/sources.list.d/sagernet.* /etc/apt/keyrings/sagernet.asc /usr/local/bin/sb
            systemctl daemon-reload || true
            echo "sing-box 已完全卸载清理！"
        else
            echo "已取消卸载"
        fi
        ;;
    *)
        echo "用法: sb [info|status|log|restart|uninstall]"
        ;;
esac
EOF

chmod +x /usr/local/bin/sb
info "已生成快捷管理命令 /usr/local/bin/sb"

# ---------- 7. 输出完整节点信息 ----------
/usr/local/bin/sb info
