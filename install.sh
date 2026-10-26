#!/bin/bash
# sing-box 一键部署脚本（稳定优先版）—— VLESS + TCP + Reality + xtls-rprx-vision
# 适配：Debian 12/13、Ubuntu 22.04 / 24.04 / 26.04 LTS
# 安装：sudo bash install.sh
# 卸载：sudo bash install.sh --uninstall   或   sudo sb uninstall
# 安装后用 sb help 查看快捷命令

set -euo pipefail
export LC_ALL=C.UTF-8
export DEBIAN_FRONTEND=noninteractive

# ===== 默认值（运行时可直接回车采用，也可手动输入覆盖）=====
DEFAULT_PORT=443
DEFAULT_SNI="itunes.apple.com"
DEFAULT_NODE_NAME="my-singbox-node"
PRESET_UUID=""          # 想固定 UUID 可填在这里，留空则自动生成
# ===== 以下无需修改 =====

CONFIG_DIR="/etc/sing-box"
CONFIG_FILE="$CONFIG_DIR/config.json"
NODE_INFO_FILE="$CONFIG_DIR/node_info.conf"
BACKUP_DIR="$CONFIG_DIR/backups"
SERVICE_OVERRIDE_DIR="/etc/systemd/system/sing-box.service.d"
LOG_PREFIX="[sing-box-setup]"

err()  { echo "$LOG_PREFIX 错误: $1" >&2; exit 1; }
info() { echo "$LOG_PREFIX $1"; }
warn() { echo "$LOG_PREFIX 警告: $1" >&2; }

# ---------- 卸载 ----------
uninstall_singbox() {
    [ "$(id -u)" -eq 0 ] || err "请用 root 权限执行卸载（sudo bash $0 --uninstall）"
    info "正在停止并清理 sing-box 服务..."
    systemctl stop sing-box 2>/dev/null || true
    systemctl disable sing-box 2>/dev/null || true
    if command -v apt-get >/dev/null 2>&1; then
        apt-get purge -y sing-box 2>/dev/null || true
        apt-get autoremove -y 2>/dev/null || true
    fi
    rm -f /etc/apt/sources.list.d/sagernet.sources /etc/apt/sources.list.d/sagernet.list
    rm -f /etc/apt/keyrings/sagernet.asc /usr/share/keyrings/sagernet.gpg
    rm -rf "$CONFIG_DIR" "$SERVICE_OVERRIDE_DIR" /var/lib/sing-box
    rm -f /usr/local/bin/sb
    systemctl daemon-reload || true
    echo ""
    echo "=================================================="
    echo "      sing-box 及相关配置已彻底卸载并清理完成！    "
    echo "=================================================="
    exit 0
}

case "${1:-}" in
    uninstall|--uninstall|-u) uninstall_singbox ;;
esac

# ---------- 0. 基础检查 ----------
[ "$(id -u)" -eq 0 ] || err "请用 root 权限运行（sudo bash $0）"
[ -r /etc/os-release ] || err "找不到 /etc/os-release，无法识别系统版本"
# shellcheck disable=SC1091
. /etc/os-release

case "${ID}:${VERSION_ID}" in
    debian:12|debian:13|ubuntu:22.04|ubuntu:24.04|ubuntu:26.04) ;;
    *)
        if [ "${FORCE:-0}" = "1" ]; then
            warn "未测试的系统 ${PRETTY_NAME}，已按 FORCE=1 强制继续"
        else
            err "不支持的系统: ${PRETTY_NAME}（仅适配 Debian 12/13、Ubuntu 22.04/24.04/26.04；如需强行运行请加 FORCE=1）"
        fi
        ;;
esac
info "系统检测通过: $PRETTY_NAME"

# ---------- 工具函数 ----------
trim() {
    local s="$1"
    s="${s//$'\r'/}"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

valid_port() {
    [[ "$1" =~ ^[0-9]+$ ]] && [ "$((10#$1))" -ge 1 ] && [ "$((10#$1))" -le 65535 ]
}

valid_sni() {
    [[ "$1" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,}$ ]]
}

valid_uuid() {
    [[ "$1" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]
}

# 端口被 sing-box 以外的进程占用时返回 0
port_busy_by_other() {
    command -v ss >/dev/null 2>&1 || return 1
    local out
    out=$(ss -Htlnp "sport = :$1" 2>/dev/null || true)
    [ -n "$out" ] || return 1
    # 只要存在一行不属于 sing-box 的监听，就视为被其他进程占用
    printf '%s\n' "$out" | grep -qv '"sing-box"'
}

# 检测 SNI 目标是否支持 TLS1.3 + h2（仅提示，不阻断）
check_sni() {
    local out
    out=$(timeout 10 openssl s_client -connect "$1:443" -servername "$1" -tls1_3 -alpn h2 </dev/null 2>&1 || true)
    echo "$out" | grep -q "TLSv1.3" && echo "$out" | grep -qi "ALPN protocol: h2"
}

# 交互输入：优先 stdin，管道执行时回退到 /dev/tty；都没有则用默认值
TTY_IN=""
if [ -t 0 ]; then
    TTY_IN="/dev/stdin"
elif [ -r /dev/tty ] && : </dev/tty 2>/dev/null; then
    TTY_IN="/dev/tty"
fi

ask() { # ask 变量名 提示 默认值
    local __var="$1" __prompt="$2" __def="$3" __ans=""
    if [ -n "$TTY_IN" ]; then
        read -e -rp "$__prompt [默认 $__def]: " __ans < "$TTY_IN" || true
    fi
    __ans=$(trim "$__ans")
    printf -v "$__var" '%s' "${__ans:-$__def}"
}

# ---------- 1. 载入已有配置（仅作端口/SNI/节点名默认值） ----------
REALITY_PORT="" REALITY_SNI="" NODE_NAME=""

if [ -f "$NODE_INFO_FILE" ]; then
    # shellcheck disable=SC1090
    . "$NODE_INFO_FILE"
    info "检测到已有节点信息：端口/SNI/节点名将作为默认值，UUID、ShortId、Reality 密钥对会全部重新随机生成"
fi
# 每次运行都重新生成凭据，不沿用旧值（仅 PRESET_UUID 非空时使用你指定的 UUID）
REALITY_UUID=$(trim "${PRESET_UUID}")
REALITY_PRIVATE_KEY="" REALITY_PUBLIC_KEY="" REALITY_SHORT_ID=""
if [ -n "$REALITY_UUID" ] && ! valid_uuid "$REALITY_UUID"; then
    err "PRESET_UUID 格式不合法: ${REALITY_UUID}（应为 xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx，或留空自动生成）"
fi

# ---------- 2. 交互输入：端口 / SNI / 节点名 ----------
while true; do
    ask IN_PORT "请输入 Reality 监听端口" "${REALITY_PORT:-$DEFAULT_PORT}"
    if ! valid_port "$IN_PORT"; then
        warn "端口不合法: $IN_PORT（需为 1-65535 的数字）"
    elif port_busy_by_other "$((10#$IN_PORT))"; then
        warn "端口 $IN_PORT 已被其他进程占用，请换一个"
    else
        break
    fi
    [ -n "$TTY_IN" ] || err "非交互模式下默认端口不可用"
done
REALITY_PORT=$((10#$IN_PORT))

while true; do
    ask IN_SNI "请输入伪装目标域名 SNI" "${REALITY_SNI:-$DEFAULT_SNI}"
    valid_sni "$IN_SNI" && break
    warn "SNI 格式不合法: $IN_SNI（应为类似 itunes.apple.com 的域名）"
    [ -n "$TTY_IN" ] || err "非交互模式下默认 SNI 不合法"
done
REALITY_SNI="$IN_SNI"

ask IN_NAME "请输入节点名称（支持中文）" "${NODE_NAME:-$DEFAULT_NODE_NAME}"
NODE_NAME="$IN_NAME"

info "已确认: 端口=${REALITY_PORT}, SNI=${REALITY_SNI}, 节点名=${NODE_NAME}"

# ---------- 3. 安装依赖与 sing-box（官方 apt 源 = 最新稳定版） ----------
info "更新软件源并安装依赖"
apt-get update -y || err "apt update 失败，请检查网络或软件源配置"
apt-get install -y curl openssl ca-certificates jq iproute2 || err "基础依赖安装失败"

if ! check_sni "$REALITY_SNI"; then
    warn "$REALITY_SNI 在本机检测未同时满足 TLS1.3 + h2，Reality 伪装目标建议选支持二者的大站，请确认域名是否合适"
fi

if ! command -v sing-box >/dev/null 2>&1; then
    info "添加 sing-box 官方 apt 源（deb822 格式，稳定版通道）"
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

    apt-get update -y || err "添加 sing-box 源后 apt update 失败"
    apt-get install -y -o Dpkg::Options::=--force-confold sing-box \
        || err "sing-box 安装失败，请检查上方 apt 输出"
else
    info "sing-box 已安装，跳过安装（升级请运行 sb upgrade）"
fi

command -v sing-box >/dev/null 2>&1 || err "sing-box 安装完成但未在 PATH 中找到"
info "已安装: $(sing-box version | head -n1)"

mkdir -p "$CONFIG_DIR" "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"

# ---------- 4. 生成密钥材料（每次运行均重新随机生成） ----------
if [ -z "$REALITY_UUID" ]; then
    REALITY_UUID=$(sing-box generate uuid) || err "生成 UUID 失败"
fi

if [ -z "$REALITY_PRIVATE_KEY" ] || [ -z "${REALITY_PUBLIC_KEY:-}" ]; then
    info "生成 Reality 密钥对"
    KEYPAIR=$(sing-box generate reality-keypair) || err "生成 Reality 密钥对失败"
    REALITY_PRIVATE_KEY=$(echo "$KEYPAIR" | awk -F': *' '/PrivateKey/ {print $2}' | tr -d ' \t\r\n')
    REALITY_PUBLIC_KEY=$(echo "$KEYPAIR" | awk -F': *' '/PublicKey/ {print $2}' | tr -d ' \t\r\n')
    [ -n "$REALITY_PRIVATE_KEY" ] && [ -n "$REALITY_PUBLIC_KEY" ] || err "Reality 密钥对解析失败"
fi

if [ -z "$REALITY_SHORT_ID" ]; then
    REALITY_SHORT_ID=$(openssl rand -hex 8)
fi

# ---------- 5. systemd：开机自启 + 异常自动重启 + 最小权限 ----------
info "配置 systemd 自动重启策略与端口绑定权限"
mkdir -p "$SERVICE_OVERRIDE_DIR"
cat > "$SERVICE_OVERRIDE_DIR/override.conf" <<'EOF'
[Unit]
StartLimitIntervalSec=300
StartLimitBurst=10

[Service]
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE
Restart=on-failure
RestartSec=5s
EOF
systemctl daemon-reload || err "systemd daemon-reload 失败"
systemctl enable sing-box || err "设置开机自启失败"

# ---------- 5.5 BBR + FQ：已开启则跳过，未开启则默认打开 ----------
enable_bbr() {
    local cc qdisc
    cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "")
    qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "")
    if [ "$cc" = "bbr" ] && [ "$qdisc" = "fq" ]; then
        info "BBR + FQ 已开启（拥塞控制=${cc}, 队列=${qdisc}），跳过"
        return 0
    fi
    info "当前拥塞控制=${cc:-未知}, 队列=${qdisc:-未知}，尝试开启 BBR + FQ"

    modprobe tcp_bbr 2>/dev/null || true
    if ! grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
        warn "当前内核不支持 BBR（OpenVZ/LXC 等容器型 VPS 无法自行开启），已跳过"
        return 0
    fi

    if modinfo tcp_bbr >/dev/null 2>&1; then
        echo "tcp_bbr" > /etc/modules-load.d/tcp_bbr.conf
    fi
    cat > /etc/sysctl.d/99-singbox-bbr.conf <<'EOF'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
    sysctl --system >/dev/null 2>&1 || true

    cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "")
    qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "")
    if [ "$cc" = "bbr" ] && [ "$qdisc" = "fq" ]; then
        info "BBR + FQ 已成功开启并持久化"
    else
        warn "已写入 /etc/sysctl.d/99-singbox-bbr.conf，但当前生效值为 ${cc:-未知}/${qdisc:-未知}，可能被 /etc/sysctl.conf 等其他配置覆盖，请手动检查"
    fi
}
enable_bbr

# ---------- 6. 保存节点信息（单一数据源，sb 命令据此重新生成配置） ----------
(
    umask 077
    for k in REALITY_UUID REALITY_PORT REALITY_SNI REALITY_PRIVATE_KEY REALITY_PUBLIC_KEY REALITY_SHORT_ID NODE_NAME; do
        printf '%s=%q\n' "$k" "${!k}"
    done > "$NODE_INFO_FILE"
)
chmod 600 "$NODE_INFO_FILE"

# ---------- 7. 安装快捷命令 sb ----------
cat > /usr/local/bin/sb <<'SBEOF'
#!/bin/bash
# sb —— sing-box 快捷管理命令
set -euo pipefail
export LC_ALL=C.UTF-8
export DEBIAN_FRONTEND=noninteractive

CONFIG_DIR="/etc/sing-box"
CONFIG_FILE="$CONFIG_DIR/config.json"
INFO_FILE="$CONFIG_DIR/node_info.conf"
BACKUP_DIR="$CONFIG_DIR/backups"
LAST_IP_FILE="$CONFIG_DIR/last_ip"
CMD="${1:-info}"
[ $# -gt 0 ] && shift

die() { echo "错误: $*" >&2; exit 1; }
need_root() { [ "$(id -u)" -eq 0 ] || die "请使用 root 运行: sudo sb $CMD"; }
load_info() {
    [ -f "$INFO_FILE" ] || die "未找到 $INFO_FILE，请先运行安装脚本"
    # shellcheck disable=SC1090
    . "$INFO_FILE"
}
save_info() {
    (
        umask 077
        for k in REALITY_UUID REALITY_PORT REALITY_SNI REALITY_PRIVATE_KEY REALITY_PUBLIC_KEY REALITY_SHORT_ID NODE_NAME; do
            printf '%s=%q\n' "$k" "${!k}"
        done > "$INFO_FILE.tmp"
    )
    mv "$INFO_FILE.tmp" "$INFO_FILE"
    chmod 600 "$INFO_FILE"
}

trim() {
    local s="$1"
    s="${s//$'\r'/}"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}
valid_port() { [[ "$1" =~ ^[0-9]+$ ]] && [ "$((10#$1))" -ge 1 ] && [ "$((10#$1))" -le 65535 ]; }
valid_sni()  { [[ "$1" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,}$ ]]; }
valid_uuid() { [[ "$1" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; }
valid_sid()  { [[ "$1" =~ ^([0-9a-fA-F]{2}){1,8}$ ]]; }

port_busy_by_other() {
    command -v ss >/dev/null 2>&1 || return 1
    local out
    out=$(ss -Htlnp "sport = :$1" 2>/dev/null || true)
    [ -n "$out" ] || return 1
    # 只要存在一行不属于 sing-box 的监听，就视为被其他进程占用
    printf '%s\n' "$out" | grep -qv '"sing-box"'
}

check_sni() {
    local out
    out=$(timeout 10 openssl s_client -connect "$1:443" -servername "$1" -tls1_3 -alpn h2 </dev/null 2>&1 || true)
    echo "$out" | grep -q "TLSv1.3" && echo "$out" | grep -qi "ALPN protocol: h2"
}

urlenc() { jq -rn --arg s "$1" '$s|@uri'; }

render_config() {
    jq -n \
        --arg uuid "$REALITY_UUID" \
        --argjson port "$((10#$REALITY_PORT))" \
        --arg sni "$REALITY_SNI" \
        --arg pk "$REALITY_PRIVATE_KEY" \
        --arg sid "$REALITY_SHORT_ID" '
    {
      log: { level: "info", timestamp: true },
      inbounds: [{
        type: "vless",
        tag: "vless-reality-in",
        listen: "::",
        listen_port: $port,
        users: [{ uuid: $uuid, flow: "xtls-rprx-vision" }],
        tls: {
          enabled: true,
          server_name: $sni,
          reality: {
            enabled: true,
            handshake: { server: $sni, server_port: 443 },
            private_key: $pk,
            short_id: [$sid]
          }
        }
      }],
      outbounds: [{ type: "direct", tag: "direct" }]
    }'
}

svc_user() {
    local u
    u=$(systemctl show sing-box.service -p User --value 2>/dev/null || true)
    if [ -n "$u" ] && [ "$u" != "root" ] && id "$u" >/dev/null 2>&1; then echo "$u"; fi
}

# 校验 → 备份 → 落地 → 重启 → 失败自动回滚
apply() {
    local tmp bak="" u grp mode
    tmp=$(mktemp)
    render_config > "$tmp" || { rm -f "$tmp"; return 1; }
    if ! sing-box check -c "$tmp"; then
        rm -f "$tmp"
        echo "新配置校验未通过，未做任何修改" >&2
        return 1
    fi

    u=$(svc_user)
    if [ -n "$u" ]; then
        grp="$u"; mode=640
        chown root:"$u" "$CONFIG_DIR"; chmod 750 "$CONFIG_DIR"
    else
        grp=root; mode=600
        chown root:root "$CONFIG_DIR"; chmod 700 "$CONFIG_DIR"
    fi

    mkdir -p "$BACKUP_DIR"; chmod 700 "$BACKUP_DIR"
    if [ -f "$CONFIG_FILE" ]; then
        bak="$BACKUP_DIR/config.json.$(date +%Y%m%d-%H%M%S).bak"
        cp -p "$CONFIG_FILE" "$bak"; chmod 600 "$bak"
    fi
    install -m "$mode" -o root -g "$grp" "$tmp" "$CONFIG_FILE"
    rm -f "$tmp"

    systemctl restart sing-box || true
    sleep 2
    if ! systemctl is-active --quiet sing-box; then
        echo "服务启动失败，最近日志：" >&2
        journalctl -u sing-box -n 20 --no-pager >&2 || true
        if [ -n "$bak" ]; then
            cp -p "$bak" "$CONFIG_FILE"
            systemctl restart sing-box || true
            echo "已回滚到旧配置" >&2
        fi
        return 1
    fi

    ls -1t "$BACKUP_DIR"/config.json.*.bak 2>/dev/null | tail -n +11 | xargs -r rm -f || true
    return 0
}

# 保存 node_info 并应用；失败则连同 node_info 一起回滚
commit() {
    local old
    old=$(mktemp)
    cp -p "$INFO_FILE" "$old" 2>/dev/null || true
    save_info
    if apply; then rm -f "$old"; return 0; fi
    if [ -s "$old" ]; then cp -p "$old" "$INFO_FILE"; fi
    rm -f "$old"
    die "应用失败，节点信息已回滚"
}

get_ip() {
    local ip="" url
    for url in https://api.ipify.org https://ipv4.icanhazip.com https://ifconfig.me; do
        ip=$(curl -s -4 --max-time 4 "$url" 2>/dev/null | tr -d ' \r\n' || true)
        [ -n "$ip" ] && { echo "$ip"; return; }
    done
    for url in https://api64.ipify.org https://ipv6.icanhazip.com; do
        ip=$(curl -s -6 --max-time 4 "$url" 2>/dev/null | tr -d ' \r\n' || true)
        [ -n "$ip" ] && { echo "$ip"; return; }
    done
    echo ""
}

build_link() {
    local ip="$1" host name_enc
    [ -n "$ip" ] || ip="<获取失败，请手动填入服务器公网IP>"
    host="$ip"
    [[ "$ip" == *:* && "$ip" != "<"* ]] && host="[$ip]"
    name_enc=$(urlenc "$NODE_NAME")
    echo "vless://${REALITY_UUID}@${host}:${REALITY_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_SNI}&fp=chrome&pbk=${REALITY_PUBLIC_KEY}&sid=${REALITY_SHORT_ID}&type=tcp#${name_enc}"
}

record_ip() {
    [ -n "$1" ] || return 0
    ( umask 077; printf '%s\n' "$1" > "$LAST_IP_FILE" )
}

show_info() {
    local ip link
    ip=$(get_ip)
    [ -f "$LAST_IP_FILE" ] || record_ip "$ip"
    link=$(build_link "$ip")
    echo ""
    echo "================ sing-box 节点配置 ================"
    echo "节点名称:    ${NODE_NAME}"
    echo "协议:        VLESS + TCP + Reality + xtls-rprx-vision"
    echo "服务器 IP:   ${ip:-<获取失败>}"
    echo "端口:        ${REALITY_PORT}"
    echo "UUID:        ${REALITY_UUID}"
    echo "Flow:        xtls-rprx-vision"
    echo "SNI:         ${REALITY_SNI}"
    echo "PublicKey:   ${REALITY_PUBLIC_KEY}"
    echo "ShortId:     ${REALITY_SHORT_ID}"
    echo "指纹(fp):    chrome"
    echo ""
    echo "分享链接:"
    echo "${link}"
    echo "=================================================="
    echo "快捷命令: sb help 查看全部"
    echo "=================================================="
}

ask_if_empty() { # ask_if_empty 当前值 提示
    local v="$1" a=""
    if [ -z "$v" ]; then
        read -e -rp "$2" a || true
        v=$(trim "$a")
    fi
    printf '%s' "$v"
}

cmd_port() {
    local p
    p=$(ask_if_empty "${1:-}" "新端口 (当前 $REALITY_PORT): ")
    valid_port "$p" || die "端口不合法: ${p:-空}"
    p=$((10#$p))
    [ "$p" != "$REALITY_PORT" ] || { echo "端口未变化 ($p)"; return; }
    if port_busy_by_other "$p"; then die "端口 $p 已被其他进程占用"; fi
    REALITY_PORT="$p"
    commit
    show_info
}

cmd_sni() {
    local s
    s=$(ask_if_empty "${1:-}" "新 SNI 域名 (当前 $REALITY_SNI): ")
    valid_sni "$s" || die "SNI 格式不合法: ${s:-空}"
    [ "$s" != "$REALITY_SNI" ] || { echo "SNI 未变化 ($s)"; return; }
    if ! check_sni "$s"; then
        echo "警告: $s 在本机检测未同时满足 TLS1.3 + h2，建议换用支持二者的大站" >&2
    fi
    REALITY_SNI="$s"
    commit
    show_info
}

cmd_name() {
    local n
    n=$(ask_if_empty "$(trim "${*:-}")" "新节点名称 (当前 $NODE_NAME): ")
    [ -n "$n" ] || die "节点名称不能为空"
    NODE_NAME="$n"
    save_info
    show_info
}

cmd_uuid() {
    local u="${1:-}"
    if [ -z "$u" ]; then u=$(sing-box generate uuid); fi
    valid_uuid "$u" || die "UUID 格式不合法: $u"
    REALITY_UUID="$u"
    commit
    show_info
}

cmd_shortid() {
    local s="${1:-}"
    if [ -z "$s" ]; then s=$(openssl rand -hex 8); fi
    valid_sid "$s" || die "ShortId 需为 2-16 位偶数长度的十六进制字符"
    REALITY_SHORT_ID="$s"
    commit
    show_info
}

gen_keypair() {
    local kp
    kp=$(sing-box generate reality-keypair)
    REALITY_PRIVATE_KEY=$(echo "$kp" | awk -F': *' '/PrivateKey/ {print $2}' | tr -d ' \t\r\n')
    REALITY_PUBLIC_KEY=$(echo "$kp" | awk -F': *' '/PublicKey/ {print $2}' | tr -d ' \t\r\n')
    [ -n "$REALITY_PRIVATE_KEY" ] && [ -n "$REALITY_PUBLIC_KEY" ] || die "Reality 密钥对生成失败"
}

cmd_key() { gen_keypair; commit; show_info; }

cmd_reset() {
    REALITY_UUID=$(sing-box generate uuid)
    REALITY_SHORT_ID=$(openssl rand -hex 8)
    gen_keypair
    commit
    show_info
}

cmd_upgrade() {
    local old new
    old=$(sing-box version | head -n1)
    echo "当前: $old"
    local ts
    ts=$(date +%Y%m%d-%H%M%S)
    mkdir -p "$BACKUP_DIR"; chmod 700 "$BACKUP_DIR"
    if [ -f "$CONFIG_FILE" ]; then cp -p "$CONFIG_FILE" "$BACKUP_DIR/config.json.upgrade-$ts.bak"; fi
    if [ -f "$INFO_FILE" ]; then cp -p "$INFO_FILE" "$BACKUP_DIR/node_info.conf.upgrade-$ts.bak"; fi
    chmod 600 "$BACKUP_DIR"/*.upgrade-"$ts".bak 2>/dev/null || true
    echo "升级前已备份配置到 $BACKUP_DIR（*.upgrade-$ts.bak）"
    apt-get update -y
    apt-get install -y --only-upgrade -o Dpkg::Options::=--force-confold sing-box
    new=$(sing-box version | head -n1)
    if [ "$old" = "$new" ]; then
        echo "已是官方源中的最新稳定版: $new"
        return
    fi
    echo "已升级: $new"
    if ! sing-box check -c "$CONFIG_FILE"; then
        echo "警告: 新内核校验当前配置失败（可能有配置项被弃用/移除），请查看上方信息" >&2
    fi
    systemctl restart sing-box || true
    sleep 2
    if systemctl is-active --quiet sing-box; then
        echo "服务运行正常"
    else
        echo "服务启动失败，日志如下；可用 sudo apt-get install sing-box=<旧版本号> 降级，配置备份见 $BACKUP_DIR" >&2
        journalctl -u sing-box -n 20 --no-pager >&2 || true
        exit 1
    fi
}

DOC_BAD=0
d_ok()   { echo "  [√] $*"; }
d_bad()  { echo "  [×] $*"; DOC_BAD=$((DOC_BAD+1)); }
d_note() { echo "  [!] $*"; }

cmd_doctor() {
    local out cc qdisc ip last errs
    echo "================ sb doctor 自检 ================"

    echo "[1] 服务状态"
    if systemctl is-active --quiet sing-box; then d_ok "sing-box 正在运行"; else d_bad "sing-box 未运行（sb log 查看日志）"; fi
    if systemctl is-enabled --quiet sing-box 2>/dev/null; then d_ok "已设置开机自启"; else d_bad "未设置开机自启（systemctl enable sing-box）"; fi

    echo "[2] 配置文件"
    if sing-box check -c "$CONFIG_FILE" >/dev/null 2>&1; then d_ok "config.json 校验通过"; else d_bad "config.json 校验失败（sb check 查看详情）"; fi

    echo "[3] 端口监听"
    out=$(ss -Htlnp "sport = :$REALITY_PORT" 2>/dev/null || true)
    if [[ "$out" == *'"sing-box"'* ]]; then
        d_ok "TCP ${REALITY_PORT} 由 sing-box 监听"
    elif [ -n "$out" ]; then
        d_bad "TCP ${REALITY_PORT} 被其他进程占用"
    else
        d_bad "TCP ${REALITY_PORT} 没有任何监听"
    fi
    d_note "外部能否连通（云安全组/防火墙）需在客户端或另一台机器上测试"

    echo "[4] BBR + FQ"
    cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "")
    qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "")
    if [ "$cc" = "bbr" ] && [ "$qdisc" = "fq" ]; then
        d_ok "已生效（拥塞控制=${cc}, 队列=${qdisc}）"
    else
        d_bad "未生效（拥塞控制=${cc:-未知}, 队列=${qdisc:-未知}）"
    fi

    echo "[5] 外网出口 IP"
    ip=$(get_ip)
    if [ -z "$ip" ]; then
        d_bad "获取出口 IP 失败（检查服务器外网连通性）"
    else
        last=""
        [ -f "$LAST_IP_FILE" ] && last=$(tr -d ' \r\n' < "$LAST_IP_FILE")
        if [ -z "$last" ]; then
            record_ip "$ip"; d_ok "当前出口 IP ${ip}（已记录，下次自检会对比）"
        elif [ "$ip" = "$last" ]; then
            d_ok "出口 IP 未变化（${ip}）"
        else
            d_bad "出口 IP 已变化：${last} → ${ip}，客户端需改用新 IP（sb info 获取新链接）"
            record_ip "$ip"
        fi
    fi

    echo "[6] SNI 目标 ${REALITY_SNI}"
    if check_sni "$REALITY_SNI"; then
        d_ok "可达，且支持 TLS1.3 + h2"
    else
        d_bad "不可达，或不满足 TLS1.3 + h2，建议 sb sni 更换"
    fi

    echo "[7] 最近 10 分钟错误日志"
    # sing-box 日志在 journald 中优先级为 info，不能用 -p err，改为按文本匹配，并排除扫描探测产生的噪音
    errs=$(journalctl -u sing-box --since "10 min ago" --no-pager -q 2>/dev/null \
        | grep -E 'ERROR|FATAL|PANIC|Failed with result' \
        | grep -v 'processed invalid connection' \
        | tail -n 3 || true)
    if [ -z "$errs" ]; then d_ok "无错误日志"; else d_bad "存在错误日志（最近几条如下）"; echo "$errs"; fi

    echo "================================================"
    if [ "$DOC_BAD" -eq 0 ]; then echo "自检结果: 全部通过"; else echo "自检结果: ${DOC_BAD} 项异常，请按上方提示处理"; fi
}

cmd_qr() {
    command -v qrencode >/dev/null 2>&1 || { apt-get install -y qrencode >/dev/null || die "安装 qrencode 失败"; }
    qrencode -t ANSIUTF8 "$(build_link "$(get_ip)")"
}

cmd_uninstall() {
    local c=""
    read -rp "确定要彻底卸载 sing-box 及其所有配置吗？[y/N]: " c || true
    if [[ "$c" =~ ^[yY]$ ]]; then
        systemctl stop sing-box 2>/dev/null || true
        systemctl disable sing-box 2>/dev/null || true
        apt-get purge -y sing-box 2>/dev/null || true
        apt-get autoremove -y 2>/dev/null || true
        rm -rf /etc/sing-box /etc/systemd/system/sing-box.service.d /var/lib/sing-box
        rm -f /etc/apt/sources.list.d/sagernet.* /etc/apt/keyrings/sagernet.asc /usr/local/bin/sb
        systemctl daemon-reload || true
        echo "sing-box 已完全卸载清理！"
        exit 0
    fi
    echo "已取消卸载"
}

usage() {
    cat <<'EOF'
用法: sb <命令> [参数]（参数省略则交互输入）

  sb / sb info        查看节点信息与分享链接
  sb port [端口]      修改端口（自动检测端口占用）
  sb sni [域名]       修改 SNI（会检测 TLS1.3 + h2）
  sb name [名称]      修改节点名称（支持中文）
  sb uuid [UUID]      随机生成/指定新 UUID
  sb shortid [ID]     随机生成/指定新 ShortId
  sb key              重新生成 Reality 密钥对
  sb reset            一次性重置 UUID + ShortId + 密钥对
  sb upgrade          升级 sing-box 内核到官方源最新稳定版（升级前自动备份配置）
  sb version          查看内核版本
  sb qr               显示分享链接二维码
  sb status|log|start|stop|restart
  sb check            校验当前配置文件
  sb doctor           一键自检（服务/端口/BBR/出口IP/SNI/错误日志）
  sb uninstall        彻底卸载

说明: 修改端口/SNI/UUID/ShortId/密钥后，客户端需更新为新的分享链接。
EOF
}

case "$CMD" in
    help|-h|--help) usage ;;
    info|"")   need_root; load_info; show_info ;;
    port)      need_root; load_info; cmd_port "${1:-}" ;;
    sni)       need_root; load_info; cmd_sni "${1:-}" ;;
    name)      need_root; load_info; cmd_name "$@" ;;
    uuid)      need_root; load_info; cmd_uuid "${1:-}" ;;
    shortid)   need_root; load_info; cmd_shortid "${1:-}" ;;
    key)       need_root; load_info; cmd_key ;;
    reset)     need_root; load_info; cmd_reset ;;
    apply)     need_root; load_info; apply || die "应用配置失败" ;;
    upgrade)   need_root; cmd_upgrade ;;
    version)   sing-box version ;;
    qr)        need_root; load_info; cmd_qr ;;
    status)    systemctl status sing-box --no-pager ;;
    log)       journalctl -u sing-box -f ;;
    start)     need_root; systemctl start sing-box && echo "sing-box 已启动" ;;
    stop)      need_root; systemctl stop sing-box && echo "sing-box 已停止" ;;
    restart)   need_root; systemctl restart sing-box && echo "sing-box 已重启" ;;
    doctor)    need_root; load_info; cmd_doctor ;;
    check)     need_root; sing-box check -c "$CONFIG_FILE" && echo "配置校验通过" ;;
    uninstall) need_root; cmd_uninstall ;;
    *)         usage ;;
esac
SBEOF
chmod +x /usr/local/bin/sb
info "已生成快捷管理命令 /usr/local/bin/sb"

# ---------- 8. 生成配置并启动 ----------
/usr/local/bin/sb apply || err "sing-box 配置应用失败，请根据上方日志排查"
info "sing-box 服务运行正常"

# ---------- 9. 输出节点信息 ----------
/usr/local/bin/sb info
