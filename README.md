# AirSIM 开发者配置工具

| 你要做什么 | 从这里开始 |
| --- | --- |
| 配置 App ID 的能力、生成 iOS 开发描述文件 | `python3 setup.py` |
| 检查已有的开发描述文件 | `python3 setup.py --verify App.mobileprovision` |
| 申请 APNs 或 VoIP 推送证书、导出 P12 给推送服务端 | `python3 push_certificate.py` |

两个脚本都支持 `--help`。在终端交互运行时会提示输入所需标识。下文用 `com.example.airsim` 举例，请替换为自己的 Bundle ID。

## 安装

在仓库目录运行以下命令。示例适用于 macOS 和 Linux，已在 Python 3.12、OpenSSL 3 上测试。校验描述文件和读取证书主题扩展时，需要 PATH 中的 OpenSSL 支持 `cms` 和 `asn1parse`。

```bash
python3 -m venv .venv
source .venv/bin/activate
python3 -m pip install -r requirements.txt
```

## 配置能力与开发描述文件

**先离线预览。** 下面的命令会列出 API 能力、需在 Apple 后台完成的项目，以及模板将检查的 App Groups。用自己的 `--app-group` 替换模板中的五个示例组，每个组传一次。默认选择模板中的六项 API 能力。

```bash
python3 setup.py --bundle com.example.airsim --app-group group.com.example.airsim
```

如果只需要推送，运行 `python3 setup.py --bundle com.example.airsim --capability PUSH_NOTIFICATIONS`。应用时在同一命令上加 `--apply`。需要多项能力时，可以重复传 `--capability`。

**连接团队账户。** 在 App Store Connect 的「用户和访问 → 集成」中获取有权管理该团队开发者资源的团队 API 密钥。以下三项供 `--apply` 和 `--list-resources` 使用。Team ID 可以在 Apple Developer 账户的会员信息中找到，校验描述文件时需要单独提供。

```bash
export ASC_KEY_ID='替换为团队 API Key ID'
export ASC_ISSUER_ID='替换为 Issuer ID'
export ASC_KEY_PATH='/实际路径/AuthKey.p8'
python3 setup.py --apply --bundle com.example.airsim --app-group group.com.example.airsim
```

核对显示的目标后输入 `YES` 才会更改账户。脚本会复用已有 App ID，跳过已启用的能力。到 Apple Developer 后台完成 App Groups 和 iCloud 容器关联、Sign in with Apple 分组以及团队所需的受限授权；`--app-group` 用于清单和校验。 [Identifiers](https://developer.apple.com/account/resources/identifiers/list)

**创建开发描述文件。** 用只读查询查看开发签名证书和已启用设备，再把显示的 **资源 ID** 传给命令。设备的 UDID、推送证书和 App Store Connect 的 Key ID 各有不同用途。

```bash
python3 setup.py --list-resources
python3 setup.py --apply --bundle com.example.airsim \
  --certificate CERT_RESOURCE_ID --device DEVICE_RESOURCE_ID \
  --app-group group.com.example.airsim --output AirSIM-dev.mobileprovision
```

多个设备可以重复传 `--device`。默认输出为 `<Bundle ID>.mobileprovision`。已有同名文件时，另选 `--output`。如果 Apple 已返回新描述文件的资源 ID，但本地保存失败，可在后台下载这一份。 [Profiles](https://developer.apple.com/account/resources/profiles/list)

**校验文件。** 提供独立确认的 Bundle ID、Team ID，以及实际使用的 App Groups。旧团队如果使用不同的 App ID Prefix，另加 `--app-id-prefix`。

```bash
python3 setup.py --verify AirSIM-dev.mobileprovision \
  --bundle com.example.airsim --team-id ABCDE12345 \
  --app-group group.com.example.airsim
```

输出涵盖 CMS 签名完整性、到期时间、团队、App ID Prefix，以及原 AirSIM 模板的 24 项授权。若要额外核验签名链，可用 `--ca-file` 指定可信的 CA PEM 文件。字段差异会导致非零退出。这个模板用于核对 AirSIM 的特定配置；合法的其他项目可能有不同的授权。现代 Apple 系统使用嵌入的 DER 描述文件做系统判定，最终还应使用实际签名的 App 在目标设备上验证。 [Apple TN3125](https://developer.apple.com/documentation/technotes/tn3125-inside-code-signing-provisioning-profiles)

## 申请 APNs / VoIP 证书并导出 P12

1. **在保存私钥的机器上生成 CSR。** 按需选择 `apns`、`voip` 或 `both`。选择 `both` 会生成两组独立密钥和请求。

   ```bash
   python3 push_certificate.py csr --bundle com.example.airsim --type both
   ```

   默认目录为 `~/.airsim-push/<Bundle ID>/<类型>/`。备份其中的 `private.key`，向 Apple 上传同目录的 `request.csr`。仅缺少 CSR 时，重跑会使用已有私钥补生成；原私钥丢失时，已签发的 CER 无法用于还原它。

2. **在 Apple 后台签发对应证书。** 常规推送选择 **Apple Push Notification service SSL (Sandbox & Production)**。申请专用 VoIP 凭据时选择 **VoIP Services Certificate**。选择目标 App ID，上传对应 CSR，然后下载 CER。如果已有通用推送证书且它明确授权了目标 `<Bundle ID>.voip` 主题，可跳过新申请，在下步用 `--type voip --key /原始路径/private.key` 复用对应的未加密 PEM 私钥。 [Apple Certificates](https://developer.apple.com/account/resources/certificates/add) · [Apple 对通用推送证书的说明](https://developer.apple.com/videos/play/wwdc2016/724/)

3. **在生成 CSR 的机器上导出。** 示例中的文件路径替换为下载位置。脚本会检查公钥、有效期和目标推送主题。VoIP 导出要求证书扩展中明确包含 `<Bundle ID>.voip`。核对显示的证书信息后，按提示设置 P12 密码。

   ```bash
   python3 push_certificate.py export --bundle com.example.airsim --type apns \
     --certificate ~/Downloads/aps.cer
   ```

   默认生成同目录的 `apns.p12` 或 `voip.p12` 以及 `certificate.pem`。证书续期需要另存时，用 `--output /目标目录/新名称.p12`。如果生成 CSR 时选了自定义 `--store`，导出时请使用相同路径。自动化导出可用 `--password-stdin` 从受保护的管道读取密码，并在人工核对证书用途后传 `--confirm-topics`。私钥和 P12 只保存在受控位置。上线前用服务端实际使用的环境、设备令牌和 topic 验证推送送达。 [Apple 证书认证指南](https://developer.apple.com/documentation/usernotifications/establishing-a-certificate-based-connection-to-apns)

## 文档依据与测试

本次核对的 App Store Connect OpenAPI 版本为 **4.6.1**，公开快照记录于 2026-11-19。它定义了能力、开发签名证书、设备、描述文件及其资源关系。团队密钥按 Apple 规定使用 ES256 签发短期 JWT。 [OpenAPI 官方下载](https://developer.apple.com/sample-code/app-store-connect/app-store-connect-openapi-specification.zip) · [核对的版本](https://github.com/EvanBacon/App-Store-Connect-OpenAPI-Spec/blob/ccb0cddcb70f9daa43673f7299e8e4958c42d59a/specs/4.6.1.json) · [Apple 的 JWT 字段说明](https://developer.apple.com/documentation/appstoreconnectapi/generating-tokens-for-api-requests) · [APNs 推送类型与证书主题](https://developer.apple.com/documentation/usernotifications/sending-notification-requests-to-apns)

在仓库目录执行离线回归测试。测试使用临时文件、本地证书和模拟 API 响应，无需登录 Apple。

```bash
python3 -m unittest discover -s tests -v
```
