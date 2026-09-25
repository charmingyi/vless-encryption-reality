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
