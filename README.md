# vless-encryption-reality（fork：仅修复 X25519 Password 解析）

上游项目：[Sanite-Ava/vless-encryption-reality](https://github.com/Sanite-Ava/vless-encryption-reality)
（教程：<https://telegra.ph/VLESS-Encryption--Reality-中转架构完整部署教程-02-19-2>，上游声明 MIT）。

本仓库**只做一处修改**，其余与上游逐字一致。

## 改了什么

较新的 Xray 把 `xray x25519` 的输出从

```
PrivateKey: <priv>
Password: <pub>
```

改成了

```
PrivateKey: <priv>
Password (PublicKey): <pub>
```

上游用 `awk '/^Password:/{print $2}'` 取值，在新版下**匹配不到任何行** → Password 为空：
落地机打印的 `X25519 Password:` 是空的、分享链接里的 `pbk=` 为空、中转机侧的客户端链接也缺这段公钥
（这就是「看不到 X25519 Password」的原因）。

```diff
-    password=$(echo "$x25519_out" | awk '/^Password:/{print $2}')
+    password=$(echo "$x25519_out" | awk '/^Password/{print $NF}')
...
-    x25519_passwd=$(echo "$x25519_out" | awk '/^Password:/{print $2}')
+    x25519_passwd=$(echo "$x25519_out" | awk '/^Password/{print $NF}')
```

兼容新旧两种输出格式，都取该行最后一个字段。**就这两行，没有其它改动。**

## 用法

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/charmingyi/vless-encryption-reality/main/install.sh)
```

先装落地机（菜单选 2），记下 UUID / X25519 Password / 公网 IP；再装中转机（菜单选 1）填入这三项。

## 已知情况（仅记录，不是本 fork 的改动）

在部分 iOS 客户端（实测 Shadowrocket）上，带 ML-KEM 的
`encryption=mlkem768x25519plus.<mode>.<rtt>.<X25519公钥>.<ML-KEM客户端>` 链接可能连不上，
而 v2rayN / v2rayNG 正常。遇到这种情况时，把 `decryption`/`encryption` 里的 ML-KEM 段去掉、只保留
X25519（官方 PR #5067 明确允许只用一个身份）即可。本仓库保持上游原样，未做此改动。
