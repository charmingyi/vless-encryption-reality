# vless-encryption-reality（fork：仅修复 X25519 Password 解析）

上游项目：[Sanite-Ava/vless-encryption-reality](https://github.com/Sanite-Ava/vless-encryption-reality)
（教程：<https://telegra.ph/VLESS-Encryption--Reality-中转架构完整部署教程-02-19-2>，上游声明 MIT）。

## 改了什么

**只改一处**：`xray x25519` 的 Password 解析。

较新的 Xray（v25.x 起）把输出从

```
PrivateKey: <priv>
Password: <pub>
```

改成了

```
PrivateKey: <priv>
Password (PublicKey): <pub>
```

上游脚本用 `awk '/^Password:/{print $2}'` 取值，在新版下**匹配不到任何行** → Password 为空，
于是落地机打印的 `X25519 Password:` 是空的、分享链接里的 `pbk=` 也是空的
（这就是"看不到 X25519 Password"的原因），中转机那侧的客户端链接同样会缺这段公钥。

本 fork 只把两处改成兼容两种格式、都取最后一个字段：

```diff
- password=$(echo "$x25519_out" | awk '/^Password:/{print $2}')
+ password=$(echo "$x25519_out" | awk '/^Password/{print $NF}')
...
- x25519_passwd=$(echo "$x25519_out" | awk '/^Password:/{print $2}')
+ x25519_passwd=$(echo "$x25519_out" | awk '/^Password/{print $NF}')
```

## 第二处修复：去掉链接里的 ML-KEM 段（为了 Shadowrocket 能连）

实测（同一台中转机、同一台 iOS 设备，逐一排除过链路/参数/`flow`/模式 `native|xorpub|random`/`0rtt|1rtt`/5 段与 4 段拼接/新旧内核 v25.9.5 与 v26.3.27）：

| 客户端 `encryption` 形态 | Shadowrocket | v2rayN |
| --- | --- | --- |
| `…0rtt.<43字符 X25519 公钥>.<700+字符 ML-KEM 客户端>`（上游默认） | ❌ 不通 | ✅ 通 |
| `…0rtt.<43字符 X25519 公钥>`（**本 fork**） | ✅ **通** | ✅ 通 |

因此本 fork 只保留 **X25519-only 身份**（Xray PR #5067 明确允许"后面 base64 至少二选一"）：

```diff
-    "decryption": "mlkem768x25519plus.xorpub.600s.${x25519_priv}.${mlkem_seed}"
+    "decryption": "mlkem768x25519plus.xorpub.600s.${x25519_priv}"
...
-    …&encryption=mlkem768x25519plus.xorpub.0rtt.${x25519_passwd}.${mlkem_client}&…
+    …&encryption=mlkem768x25519plus.xorpub.0rtt.${x25519_passwd}&…
```

协议、端口、Reality 出站、Vision 全部不变；代价是**少了 ML-KEM 的抗量子那一半**（前向安全与 0-RTT 保留）。
如果要抗量子，把上面两行的 `.${mlkem_seed}` / `.${mlkem_client}` 加回去即可（并去掉两行注释掉即可），但那样 Shadowrocket 就连不上。

其余逻辑与上游**完全一致**（未做任何其它改动）。

## 用法

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/charmingyi/vless-encryption-reality/main/install.sh)
```

先装落地机（菜单选 `2`），记下输出的 **UUID / X25519 Password / 公网 IP**；
再装中转机（菜单选 `1`），按提示输入这三项，最后导入输出的客户端分享链接。

## 已验证

- `bash -n` 语法检查通过；
- 新旧两种 `xray x25519` 输出都能正确取到 Password（`PRIV123` / `PUB456`）；
- 上游未修版本在新格式下取到空值（复现问题）。

## 说明

本仓库仅为方便使用而复制上游脚本 + 一处修复，版权与设计归上游作者所有。
上游若已自行修好，请以官方仓库为准。
