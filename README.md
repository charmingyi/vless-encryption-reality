# vless-encryption-reality（fork）

上游项目：[Sanite-Ava/vless-encryption-reality](https://github.com/Sanite-Ava/vless-encryption-reality)
（教程：<https://telegra.ph/VLESS-Encryption--Reality-中转架构完整部署教程-02-19-2>，上游声明 MIT）。

本仓库基于上游脚本，**只做了四处改动**，协议与流程不变。

## 1. 修复新版 Xray 取不到 X25519 Password

新版 Xray 把 `xray x25519` 的输出从 `Password: <pub>` 改成了 `Password (PublicKey): <pub>`，
上游用 `awk '/^Password:/{print $2}'` 匹配不到 → Password 为空（落地机打印为空、链接里 `pbk` 为空）。

```diff
- password=$(echo "$x25519_out" | awk '/^Password:/{print $2}')
+ password=$(echo "$x25519_out" | awk '/^Password/{print $NF}')
```

## 2. 二进制/服务名改为 gatewayd

利群自查脚本有进程名黑名单（`xray|v2ray|sing-box|...`，命中直接判 HIGH，理由 "Proxy stack process"）。
脚本安装后会把 `/usr/local/bin/xray` 改名为 `/usr/local/bin/gatewayd`，systemd 单元改成
`gatewayd.service`（配置路径不变）。实测改名后该条命中消失。

## 3. 中转机 → 落地机这一跳由 Reality 改为 VLESS Encryption

Reality 出站会带 `speed.cloudflare.com` 的 SNI 指向落地机 IP，会命中利群的 **SNI Mismatch** 规则。
改成 Encryption 后出口方向**不带任何 SNI**（`security: none`），实测出口侧干净。

因此：

| 角色 | 入站 | 出站 |
| --- | --- | --- |
| 落地机 | VLESS Encryption（`decryption=…600s.<X25519私钥>`） | freedom |
| 中转机 | VLESS Encryption（对客户端） | VLESS Encryption（到落地机，无 SNI） |

## 4. 加密身份只用 X25519（小火箭兼容）

实测（同一台中转机、同一台 iOS 设备，排除过链路/`flow`/模式 `native|xorpub|random`/`0rtt|1rtt`/5 段与 4 段/
新旧内核 v25.9.5 与 v26.3.27）：

| 客户端 `encryption` 形态 | Shadowrocket | v2rayN |
| --- | --- | --- |
| `…0rtt.<X25519公钥>.<700+字符 ML-KEM客户端>`（上游默认） | 无法导入/无法连接 | 正常 |
| `…0rtt.<X25519公钥>`（**本 fork**） | **可用** | 正常 |

所以落地机与中转机的 `decryption` 只保留 X25519，分享链接的 `encryption` 也只保留 X25519
（官方 PR #5067 明确允许 base64 至少二选一）。代价是失去 ML-KEM 的抗量子那一半，前向安全与 0-RTT 保留。

落地机不再直接对外提供节点，只接收中转机的 Encryption 连接；安装完成后它会打印中转机需要的
**UUID / Encryption 串 / 公网 IP / 端口**。

## 用法

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/charmingyi/vless-encryption-reality/main/install.sh)
```

1. 先装**落地机**（菜单选 `2`），记下它输出的 UUID、Encryption 串、公网 IP、端口；
2. 再装**中转机**（菜单选 `1`），把上面四项填进去；
3. 中转机装完会输出客户端分享链接。

## 注意

- 脚本输出的分享链接里用的是 `curl ifconfig.me` 取到的 IPv4。**如果入口机的公网 IPv4 是运营商 NAT 出口
  （不可入站，只有 IPv6 公网），必须把链接里的地址换成域名或 IPv6 字面量**，否则客户端连不上。
- 想要抗量子：把 `decryption`/`encryption` 里的 ML-KEM 段加回去即可（但那会让 Shadowrocket 无法使用）。
- 本仓库相对上游只做上面四处改动，其余逐字一致。
