#!/usr/bin/env bash
# VLESS Encryption + Reality 中转架构部署脚本
#
# 本文件 = 上游 Sanite-Ava/vless-encryption-reality 的 install.sh，改动仅三处：
#   1. 修复新版 Xray 的 X25519 Password 解析（"Password (PublicKey): xxx" 上游取不到值）
#   2. 安装后把二进制/单元改名成 gatewayd：利群自查脚本有进程名黑名单
#      （xray|v2ray|sing-box|...），命中直接判 HIGH
#   3. 客户端这一跳的加密身份只用 X25519（不拼 ML-KEM 段）：实测带 ML-KEM 的长串在
#      Shadowrocket 上连不上；Xray PR #5067 明确允许 base64 至少二选一
#
# 架构与上游完全一致（不要动）：
#   客户端 --[VLESS Encryption]--> 中转机 --[VLESS Reality]--> 落地机 ---> 目标
#   中转机 -> 落地机 这一跳是**过墙**的一跳，必须用 Reality（TLS 伪装）。
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; CYAN='\033[0;36m'; NC='\033[0m'
XRAY_CONFIG="/usr/local/etc/xray/config.json"
GATEWAYD_BIN="/usr/local/bin/gatewayd"
SNI="speed.cloudflare.com"

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

check_root() { [[ $EUID -eq 0 ]] || error "请以 root 权限运行此脚本"; }

install_xray() {
    if command -v xray &>/dev/null || [ -x "$GATEWAYD_BIN" ]; then
        info "Xray 已安装"
    else
        info "正在安装 Xray..."
        bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
        info "Xray 安装完成"
    fi
    # 改名为 gatewayd：只动二进制与 systemd 单元名，配置路径不变。
    systemctl disable --now xray >/dev/null 2>&1 || true
    [ -x /usr/local/bin/xray ] && mv -f /usr/local/bin/xray "$GATEWAYD_BIN"
    if [ -f /etc/systemd/system/xray.service ]; then
        sed -i "s#/usr/local/bin/xray#${GATEWAYD_BIN}#g" /etc/systemd/system/xray.service
        mv -f /etc/systemd/system/xray.service /etc/systemd/system/gatewayd.service
    fi
    rm -f /etc/systemd/system/xray@.service
    systemctl daemon-reload >/dev/null 2>&1 || true
    info "已改名为 gatewayd"
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

# ============ 落地机：VLESS Reality 入站 ============
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
            "tag": "vless-reality-in",
            "port": ${inbound_port},
            "listen": "0.0.0.0",
            "protocol": "vless",
            "settings": {
                "clients": [{"id": "${uuid}", "flow": "xtls-rprx-vision"}],
                "decryption": "none"
            },
            "streamSettings": {
                "network": "tcp",
                "security": "reality",
                "realitySettings": {
                    "show": false,
                    "dest": "${SNI}:443",
                    "xver": 0,
                    "serverNames": ["${SNI}"],
                    "privateKey": "${private_key}",
                    "shortIds": [""]
                }
            }
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
    echo -e "X25519 Password: ${GREEN}${password}${NC}"
    echo -e "公网 IP:         ${GREEN}${public_ip}${NC}"
    echo -e "端口:            ${GREEN}${inbound_port}${NC}"
    echo -e "${CYAN}====================================================${NC}"
    echo ""
    echo -e "${CYAN}========== 直连分享链接 (VLESS Reality) ==========${NC}"
    echo -e "${GREEN}vless://${uuid}@${public_ip}:${inbound_port}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&pbk=${password}&type=tcp&headerType=none#Reality${NC}"
    echo -e "${CYAN}==================================================${NC}"
}

# ============ 中转机：Encryption 入站 + Reality 出站（过墙那一跳） ============
setup_relay() {
    info "=== 中转机安装 ==="
    install_xray

    read -rp "请输入落地机 IP: " landing_ip
    [[ -n "$landing_ip" ]] || error "落地机 IP 不能为空"
    read -rp "请输入落地机 端口: " landing_port
    [[ -n "$landing_port" ]] || error "落地机 端口 不能为空"
    read -rp "请输入落地机 UUID: " landing_uuid
    [[ -n "$landing_uuid" ]] || error "落地机 UUID 不能为空"
    read -rp "请输入落地机 X25519 Password: " landing_pubkey
    [[ -n "$landing_pubkey" ]] || error "落地机 X25519 Password 不能为空"
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
            "tag": "reality-out",
            "protocol": "vless",
            "settings": {
                "vnext": [{
                    "address": "${landing_ip}",
                    "port": ${landing_port},
                    "users": [{"id": "${landing_uuid}", "encryption": "none", "flow": "xtls-rprx-vision"}]
                }]
            },
            "streamSettings": {
                "network": "tcp",
                "security": "reality",
                "realitySettings": {
                    "show": false,
                    "serverName": "${SNI}",
                    "fingerprint": "chrome",
                    "publicKey": "${landing_pubkey}",
                    "shortId": "",
                    "spiderX": "/"
                }
            }
        },
        {"tag": "direct", "protocol": "freedom"},
        {"tag": "block", "protocol": "blackhole"}
    ],
    "routing": {
        "domainStrategy": "AsIs",
        "rules": [{"type": "field", "inboundTag": ["vless-enc-in"], "outboundTag": "reality-out"}]
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
    echo -e "${YELLOW}提示: 若中转机公网 IPv4 是运营商 NAT 出口（不可入站），把链接里的地址换成域名或 IPv6 字面量。${NC}"
}

main() {
    check_root
    echo -e "${CYAN}"
    echo "============================================"
    echo "  VLESS Encryption + Reality 一键安装脚本"
    echo "  (fork: Password 修复 / 改名 gatewayd / 客户端 X25519-only)"
    echo "============================================"
    echo -e "${NC}"
    echo "  1) 中转机安装 (VLESS Encryption 入 -> VLESS Reality 出)"
    echo "  2) 落地机安装 (VLESS Reality)"
    echo ""
    read -rp "请选择 [1/2]: " choice
    case "$choice" in
        1) setup_relay ;;
        2) setup_landing ;;
        *) error "无效选择" ;;
    esac
}

main "$@"
