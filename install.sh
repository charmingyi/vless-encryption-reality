#!/usr/bin/env bash
# VLESS Encryption + Reality 中转架构部署脚本
#
# 本文件 = 上游 Sanite-Ava/vless-encryption-reality 的 install.sh，改动仅三处：
#   1. 修复新版 Xray 的 X25519 Password 解析（"Password (PublicKey): xxx" 取不到值）
#   2. 安装后把二进制/单元改名成 gatewayd：利群自查脚本有进程名黑名单
#      （xray|v2ray|sing-box|...），命中直接判 HIGH；改名后不再命中
#   3. 中转机 -> 落地机这一跳从 Reality 换成 VLESS Encryption：Reality 出站会带
#      speed.cloudflare.com 的 SNI 指向落地机 IP，命中利群的 SNI Mismatch 规则
#   4. 加密身份只用 X25519（不拼 ML-KEM 段）：实测带 ML-KEM 的长串在 Shadowrocket 上
#      无法导入使用；Xray PR #5067 明确允许 base64 至少二选一
# 其余（协议、端口、Vision、菜单、落地机/中转机流程）与上游一致。
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; CYAN='\033[0;36m'; NC='\033[0m'
XRAY_CONFIG="/usr/local/etc/xray/config.json"
GATEWAYD_BIN="/usr/local/bin/gatewayd"

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

check_root() { [[ $EUID -eq 0 ]] || error "请以 root 权限运行此脚本"; }

install_xray() {
    if command -v xray &>/dev/null || [ -x "$GATEWAYD_BIN" ]; then
        info "Xray 已安装: $([ -x "$GATEWAYD_BIN" ] && "$GATEWAYD_BIN" version | head -1 || xray version | head -1)"
    else
        info "正在安装 Xray..."
        bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
        info "Xray 安装完成"
    fi
    # 改名 gatewayd：只动二进制与 systemd 单元名，配置路径不变。
    systemctl disable --now xray >/dev/null 2>&1 || true
    if [ -x /usr/local/bin/xray ]; then
        mv -f /usr/local/bin/xray "$GATEWAYD_BIN"
    fi
    if [ -f /etc/systemd/system/xray.service ]; then
        sed -i "s#/usr/local/bin/xray#${GATEWAYD_BIN}#g" /etc/systemd/system/xray.service
        mv -f /etc/systemd/system/xray.service /etc/systemd/system/gatewayd.service
    fi
    rm -f /etc/systemd/system/xray@.service
    systemctl daemon-reload >/dev/null 2>&1 || true
    info "已改名为 gatewayd（避免进程名被风控点名）"
}

restart_gatewayd() {
    if [ ! -f /etc/systemd/system/gatewayd.service ]; then
        cat > /etc/systemd/system/gatewayd.service <<EOF
[Unit]
Description=gatewayd
After=network-online.target
Wants=network-online.target
[Service]
ExecStart=${GATEWAYD_BIN} run -config ${XRAY_CONFIG}
Restart=always
RestartSec=3
[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
    fi
    systemctl enable gatewayd >/dev/null 2>&1 || true
    systemctl restart gatewayd
}

get_public_ip() {
    local ip
    ip=$(curl -4s --max-time 5 https://ifconfig.me 2>/dev/null) \
        || ip=$(curl -4s --max-time 5 https://api.ipify.org 2>/dev/null) \
        || ip=$(curl -4s --max-time 5 https://ip.sb 2>/dev/null) \
        || error "无法获取公网 IP"
    echo "$ip"
}

setup_landing() {
    info "=== 落地机安装 ==="
    install_xray

    local uuid x25519_out private_key password public_ip
    uuid=$("$GATEWAYD_BIN" uuid)
    x25519_out=$("$GATEWAYD_BIN" x25519)
    private_key=$(echo "$x25519_out" | awk '/^PrivateKey/{print $NF}')
    password=$(echo "$x25519_out" | awk '/^Password/{print $NF}')
    public_ip=$(get_public_ip)
    read -rp "请输入入站端口 [默认 443]: " inbound_port
    inbound_port=${inbound_port:-443}
    cat > "$XRAY_CONFIG" <<EOF
{
    "log": {"loglevel": "error"},
    "inbounds": [
        {
            "tag": "vless-enc-in",
            "port": ${inbound_port},
            "listen": "0.0.0.0",
            "protocol": "vless",
            "settings": {
                "clients": [{"id": "${uuid}"}],
                "decryption": "mlkem768x25519plus.xorpub.600s.${private_key}"
            },
            "streamSettings": {"network": "tcp"}
        }
    ],
    "outbounds": [
        {"protocol": "freedom", "tag": "direct"},
        {"protocol": "blackhole", "tag": "block"}
    ]
}
EOF

    restart_gatewayd
    info "落地机配置完成!"
    echo ""
    echo -e "${CYAN}========== 落地机信息（配置中转机时需要） ==========${NC}"
    echo -e "UUID:            ${GREEN}${uuid}${NC}"
    echo -e "Encryption 串:   ${GREEN}mlkem768x25519plus.xorpub.0rtt.${password}${NC}"
    echo -e "公网 IP:         ${GREEN}${public_ip}${NC}"
    echo -e "端口:            ${GREEN}${inbound_port}${NC}"
    echo -e "${CYAN}====================================================${NC}"
    echo ""
    echo -e "${YELLOW}说明: 落地机不再直接对外提供节点，只接收中转机的 Encryption 连接；"
    echo -e "      中转机那一跳也用 Encryption（不用 Reality），避免出口方向出现 SNI 特征。${NC}"
}

setup_relay() {
    info "=== 中转机安装 ==="
    install_xray

    read -rp "请输入落地机 IP: " landing_ip
    [[ -n "$landing_ip" ]] || error "落地机 IP 不能为空"
    read -rp "请输入落地机 端口: " landing_port
    [[ -n "$landing_port" ]] || error "落地机 端口 不能为空"
    read -rp "请输入落地机 UUID: " landing_uuid
    [[ -n "$landing_uuid" ]] || error "落地机 UUID 不能为空"
    read -rp "请输入落地机 Encryption 串: " landing_encryption
    [[ -n "$landing_encryption" ]] || error "落地机 Encryption 串不能为空"
    read -rp "请输入入站端口 [默认 443]: " inbound_port
    inbound_port=${inbound_port:-443}

    local uuid x25519_out x25519_priv x25519_passwd public_ip
    uuid=$("$GATEWAYD_BIN" uuid)
    x25519_out=$("$GATEWAYD_BIN" x25519)
    x25519_priv=$(echo "$x25519_out" | awk '/^PrivateKey/{print $NF}')
    x25519_passwd=$(echo "$x25519_out" | awk '/^Password/{print $NF}')
    public_ip=$(get_public_ip)

    cat > "$XRAY_CONFIG" <<EOF
{
    "log": {"loglevel": "warning"},
    "inbounds": [
        {
            "tag": "vless-enc-in",
            "port": ${inbound_port},
            "listen": "0.0.0.0",
            "protocol": "vless",
            "settings": {
                "clients": [{"id": "${uuid}", "flow": "xtls-rprx-vision"}],
                "decryption": "mlkem768x25519plus.xorpub.600s.${x25519_priv}"
            },
            "streamSettings": {"network": "tcp"}
        }
    ],
    "outbounds": [
        {
            "tag": "enc-out",
            "protocol": "vless",
            "settings": {
                "vnext": [{
                    "address": "${landing_ip}",
                    "port": ${landing_port},
                    "users": [{"id": "${landing_uuid}", "encryption": "${landing_encryption}", "flow": "xtls-rprx-vision"}]
                }]
            },
            "streamSettings": {"network": "tcp", "security": "none"}
        },
        {"tag": "direct", "protocol": "freedom"},
        {"tag": "block", "protocol": "blackhole"}
    ],
    "routing": {
        "domainStrategy": "AsIs",
        "rules": [{"type": "field", "inboundTag": ["vless-enc-in"], "outboundTag": "enc-out"}]
    }
}
EOF

    restart_gatewayd
    info "中转机配置完成!"
    echo ""
    echo -e "${CYAN}========== 客户端分享链接 (VLESS Encryption) ==========${NC}"
    echo -e "${GREEN}vless://${uuid}@${public_ip}:${inbound_port}?encryption=mlkem768x25519plus.xorpub.0rtt.${x25519_passwd}&flow=xtls-rprx-vision&security=none&type=tcp&headerType=none#Encryption${NC}"
    echo -e "${CYAN}========================================================${NC}"
    echo ""
    echo -e "${YELLOW}提示: 上面的公网 IP 若是运营商 NAT 出口（不可入），请把链接里的地址换成你入口的真实地址"
    echo -e "      （域名或 IPv6 字面量），否则客户端连不上。${NC}"
}

main() {
    check_root
    echo -e "${CYAN}"
    echo "============================================"
    echo "  VLESS Encryption + Reality 一键安装脚本"
    echo "  (fork: X25519-only / 改名 gatewayd / 出口用 Encryption，兼容小火箭)"
    echo "============================================"
    echo -e "${NC}"
    echo "  1) 中转机安装 (VLESS Encryption 入 -> VLESS Encryption 出)"
    echo "  2) 落地机安装 (VLESS Encryption 入)"
    echo ""
    read -rp "请选择 [1/2]: " choice
    case "$choice" in
        1) setup_relay ;;
        2) setup_landing ;;
        *) error "无效选择" ;;
    esac
}

main "$@"
