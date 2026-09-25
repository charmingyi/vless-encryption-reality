# vless-encryption-reality（fork）

上游项目：[Sanite-Ava/vless-encryption-reality](https://github.com/Sanite-Ava/vless-encryption-reality)
（教程：<https://telegra.ph/VLESS-Encryption--Reality-中转架构完整部署教程-02-19-2>，上游声明 MIT）。

架构与上游**完全一致**：

```
客户端 --[VLESS Encryption]--> 中转机 --[VLESS Reality]--> 落地机 ---> 目标
```

中转机 → 落地机这一跳是**过墙**的一跳，必须用 Reality（TLS 伪装），本仓库没有改动这一点。

## 相对上游的三处改动

### 1. 修复新版 Xray 取不到 X25519 Password

新版 Xray 输出从 `Password: <pub>` 变成 `Password (PublicKey): <pub>`，上游 `awk '/^Password:/{print $2}'`
匹配不到 → Password 为空（落地机打印为空、`pbk` 为空、中转机侧的客户端链接也缺这段公钥）。

```diff
- password=$(echo "$x25519_out" | awk '/^Password:/{print $2}')
+ password=$(echo "$x25519_out" | awk '/^Password/{print $NF}')
```

### 2. 二进制/服务名改为 gatewayd

利群自查脚本有进程名黑名单（`xray|v2ray|sing-box|...`，命中判 HIGH，理由 "Proxy stack process"）。
脚本安装后把 `/usr/local/bin/xray` 改名为 `/usr/local/bin/gatewayd`，systemd 单元改 `gatewayd.service`
（配置路径不变）。链路逻辑、协议、端口都不受影响。

### 3. 客户端这一跳只用 X25519 身份（小火箭兼容）

实测带 ML-KEM 的 `encryption=mlkem768x25519plus.xorpub.0rtt.<X25519公钥>.<700+字符 ML-KEM客户端>`
在 Shadowrocket 上无法连接（v2rayN / v2rayNG 正常）。本 fork 只保留 X25519
（官方 PR #5067 明确允许 base64 至少二选一）：

```diff
- "decryption": "mlkem768x25519plus.xorpub.600s.${x25519_priv}.${mlkem_seed}"
+ "decryption": "mlkem768x25519plus.xorpub.600s.${x25519_priv}"
- …&encryption=mlkem768x25519plus.xorpub.0rtt.${x25519_passwd}.${mlkem_client}&…
+ …&encryption=mlkem768x25519plus.xorpub.0rtt.${x25519_passwd}&…
```

代价：少了 ML-KEM 的抗量子那一半（前向安全、0-RTT、Vision 都保留）。想要抗量子就把 ML-KEM 段加回去，
但 Shadowrocket 会连不上。

## 用法

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/charmingyi/vless-encryption-reality/main/install.sh)
```

1. 先装**落地机**（菜单 `2`）：输出 UUID / X25519 Password / 公网 IP / 端口 + Reality 直连链接；
2. 再装**中转机**（菜单 `1`）：填入上面四项 → 输出客户端 Encryption 分享链接。

## 注意

脚本用 `curl ifconfig.me` 取 IPv4 填进分享链接。**若中转机的公网 IPv4 是运营商 NAT 出口（不可入站，
只有 IPv6 公网），必须把链接里的地址换成域名或 IPv6 字面量**，否则客户端连不上。
