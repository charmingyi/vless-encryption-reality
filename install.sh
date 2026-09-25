#!/usr/bin/env bash
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; CYAN='\033[0;36m'; NC='\033[0m'
XRAY_CONFIG="/usr/local/etc/xray/config.json"

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

check_root() { [[ $EUID -eq 0 ]] || error "请以 root 权限运行此脚本"; }

install_xray() {
    if command -v xray &>/dev/null; then
        info "Xray 已安装: $(xray version | head -1)"
        return
    fi
    info "正在安装 Xray..."
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
    info "Xray 安装完成"
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
    uuid=$(xray uuid)
    x25519_out=$(xray x25519)
    private_key=$(echo "$x25519_out" | awk '/^PrivateKey:/{print $2}')
    password=$(echo "$x25519_out" | awk '/^Password/{print $NF}')
    public_ip=$(get_public_ip)
    read -rp "请输入入站端口 [默认 443]: " inbound_port
    inbound_port=${inbound_port:-443}
    cat > "$XRAY_CONFIG" <<EOF
{
    "log": {"loglevel": "error"},
    "inbounds": [
        {
            "tag": "dokodemo-in",
            "port": ${inbound_port},
            "protocol": "dokodemo-door",
            "settings": {"address": "127.0.0.1", "port": 4431, "network": "tcp"},
            "sniffing": {"enabled": true, "destOverride": ["tls"], "routeOnly": true}
        },
        {
            "listen": "127.0.0.1",
            "port": 4431,
            "protocol": "vless",
            "settings": {
                "clients": [{"id": "${uuid}", "flow": "xtls-rprx-vision"}],
                "decryption": "none"
            },
            "streamSettings": {
                "network": "tcp",
                "security": "reality",
                "realitySettings": {
                    "dest": "speed.cloudflare.com:443",
                    "serverNames": ["speed.cloudflare.com"],
                    "privateKey": "${private_key}",
                    "shortIds": [""]
                }
            },
            "sniffing": {"enabled": true, "destOverride": ["http", "tls", "quic"], "routeOnly": true}
        }
    ],
    "outbounds": [
        {"protocol": "freedom", "tag": "direct"},
        {"protocol": "blackhole", "tag": "block"}
    ],
    "routing": {
        "rules": [
            {"inboundTag": ["dokodemo-in"], "domain": ["speed.cloudflare.com"], "outboundTag": "direct"},
            {"inboundTag": ["dokodemo-in"], "outboundTag": "block"}
        ]
    }
}
EOF

    systemctl restart xray && systemctl enable xray
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
    echo -e "${GREEN}vless://${uuid}@${public_ip}:${inbound_port}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=speed.cloudflare.com&pbk=${password}&type=tcp&headerType=none#Reality${NC}"
    echo -e "${CYAN}==================================================${NC}"
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
    read -rp "请输入落地机 X25519 Password: " landing_pubkey
    [[ -n "$landing_pubkey" ]] || error "落地机 X25519 Password 不能为空"
    read -rp "请输入入站端口 [默认 443]: " inbound_port
    inbound_port=${inbound_port:-443}

    local uuid x25519_out x25519_priv x25519_passwd mlkem_out mlkem_seed mlkem_client public_ip
    uuid=$(xray uuid)
    x25519_out=$(xray x25519)
    x25519_priv=$(echo "$x25519_out" | awk '/^PrivateKey:/{print $2}')
    x25519_passwd=$(echo "$x25519_out" | awk '/^Password/{print $NF}')
    mlkem_out=$(xray mlkem768)
    mlkem_seed=$(echo "$mlkem_out" | awk '/^Seed:/{print $2}')
    mlkem_client=$(echo "$mlkem_out" | awk '/^Client:/{print $2}')
    public_ip=$(get_public_ip)

    cat > "$XRAY_CONFIG" <<EOF
{
    "log": {"loglevel": "warning"},
    "inbounds": [
        {
            "tag": "vless-in",
            "port": ${inbound_port},
            "listen": "0.0.0.0",
            "protocol": "vless",
            "settings": {
                "clients": [{"id": "${uuid}", "flow": "xtls-rprx-vision"}],
                "decryption": "mlkem768x25519plus.xorpub.600s.${x25519_priv}.${mlkem_seed}"
            },
            "streamSettings": {"network": "tcp"}
        }
    ],
    "outbounds": [
        {
            "tag": "vless-reality-out",
            "protocol": "vless",
            "settings": {
                "vnext": [{
                    "address": "${landing_ip}",
                    "port": ${landing_port},
                    "users": [{"id": "${landing_uuid}", "security": "auto", "encryption": "none", "flow": "xtls-rprx-vision"}]
                }]
            },
            "streamSettings": {
                "network": "tcp",
                "security": "reality",
                "realitySettings": {
                    "serverName": "speed.cloudflare.com",
                    "fingerprint": "chrome",
                    "show": false,
                    "publicKey": "${landing_pubkey}",
                    "shortId": "",
                    "spiderX": "/",
                    "mldsa65Verify": ""
                }
            }
        },
        {"tag": "direct", "protocol": "freedom"},
        {"tag": "block", "protocol": "blackhole"}
    ],
    "routing": {
        "domainStrategy": "AsIs",
        "rules": [{"type": "field", "inboundTag": ["vless-in"], "outboundTag": "vless-reality-out"}]
    }
}
EOF

    systemctl restart xray && systemctl enable xray
    info "中转机配置完成!"
    echo ""
    echo -e "${CYAN}========== 客户端分享链接 (VLESS Encryption) ==========${NC}"
    echo -e "${GREEN}vless://${uuid}@${public_ip}:${inbound_port}?encryption=mlkem768x25519plus.xorpub.0rtt.${x25519_passwd}.${mlkem_client}&flow=xtls-rprx-vision&security=none&type=tcp&headerType=none#Encryption${NC}"
    echo -e "${CYAN}========================================================${NC}"
}

main() {
    check_root
    echo -e "${CYAN}"
    echo "============================================"
    echo "  VLESS Encryption + Reality 一键安装脚本"
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
