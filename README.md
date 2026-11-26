# AirSIM 客户端与苹果开发者工具

本仓库提供 AirSIM 安卓与 iOS 的公开通用源码，供自建 Relay 的用户使用。使用安卓网关时，请填写可以通过局域网或隧道访问的 HTTPS Relay 地址。iPhone 本机线路直接使用运营商网络。

| 平台 | 版本 | 源码与说明 | 安装包 |
| --- | --- | --- | --- |
| 安卓 Standalone | 0.9.8.27-home.12（153） | [安卓源码、安装与构建](android-client/) | [下载签名 APK](https://raw.githubusercontent.com/Milk-lpy/airsimdebug/main/binaries/android/AirSIM-Android-153.apk) |
| iPhone 与 Apple Watch | **0.9.9（198）**，APNs Sandbox | [拨号线路与安卓网关短信](ios-client/BUILD-198.md) | [下载通用未签名 IPA](binaries/ios/AirSIM-iOS-0.9.9-build198-Sandbox-full-unsigned.ipa?raw=true) · [SHA-256](binaries/ios/AirSIM-iOS-0.9.9-build198-Sandbox-full-unsigned.ipa.sha256) |
| iOS 旧版 | 0.9.9（196），APNs Sandbox | [本机双卡、默认线路和历史自检](ios-client/BUILD-196.md) · [导入旧记录](ios-client/tools/) | [下载 196 未签名 IPA](binaries/ios/AirSIM-iOS-0.9.9-build196-Sandbox-full-unsigned.ipa?raw=true) · [SHA-256](binaries/ios/AirSIM-iOS-0.9.9-build196-Sandbox-full-unsigned.ipa.sha256) |
| iOS 旧版 | 0.9.9（195），APNs Sandbox | [本机双卡、通话记录、短信与签名](ios-client/BUILD-195.md) · [导入旧记录](ios-client/tools/) | [下载 195 未签名 IPA](binaries/ios/AirSIM-iOS-0.9.9-build195-Sandbox-full-unsigned.ipa?raw=true) · [SHA-256](binaries/ios/AirSIM-iOS-0.9.9-build195-Sandbox-full-unsigned.ipa.sha256) |
| iOS 上一版 | 0.9.9（194），APNs Sandbox | [194 源码](https://github.com/Milk-lpy/airsimdebug/tree/d54fbdabb895122bd2cadc9f79efd6ce930560ed/ios-client/iOS) · [194 构建说明](ios-client/BUILD-194.md) | [下载完整未签名 IPA](https://raw.githubusercontent.com/Milk-lpy/airsimdebug/main/binaries/ios/AirSIM-iOS-0.9.9-build194-Sandbox-full-unsigned.ipa) · [SHA-256](binaries/ios/AirSIM-iOS-0.9.9-build194-Sandbox-full-unsigned.ipa.sha256) |

安卓包支持 Android 10 及以上，沿用家庭版签名。通用版使用系统信任的 HTTPS 证书。家庭网关使用专用 CA 时，请参考安卓构建说明。APK SHA-256 为 `3eb09f284b3755cb941c804a7359377ceb29c657eb3f395ebee0839866fc485a`。

iOS 完整包包含 iPhone App、通知服务扩展、Live Activity 和 Watch App。安装需要为各目标重新签名。自建服务见 [AirSIM Relay](https://github.com/Milk-lpy/airsim-relay)。客户端沿用 [AirSIM 上游](https://github.com/kai-wu-cortex/AirSIM) 的 PolyForm Noncommercial 1.0.0 许可，源码目录内附许可、署名和第三方声明。

## Apple Developer 配置工具

交互式配置 Apple Developer Bundle ID，并校验原模板的 24 项签名授权字段。

### 使用
需要 Python 3、OpenSSL 和 App Store Connect API 团队密钥（不是 APNs 密钥）。

```bash
python3 -m pip install -r requirements.txt
export ASC_KEY_ID="YOUR_KEY_ID"
export ASC_ISSUER_ID="YOUR_ISSUER_ID"
export ASC_KEY_PATH="/path/AuthKey.p8"
python3 setup.py
python3 setup.py --apply
```

运行时输入 Bundle ID，确认 YES 后才修改账号。也可使用 --bundle 指定标识。

人工补齐特殊权限、关联 App Groups 后，可使用：
```bash
python3 setup.py --apply --certificate CERT_RESOURCE_ID --device DEVICE_RESOURCE_ID
python3 setup.py --verify AirSIM-generated.mobileprovision
```

### 限制
官方 API 仅尝试启用脚本 CAPS 列出的能力。默认通信权限、内存增强权限、通信通知等需后台操作或苹果审批。App Groups 需人工创建和关联，原模板五个组名可能不适用于其他团队。iCloud 与 Apple 登录可能需要额外配置。校验模板位于 setup.py 的 EXPECTED，Team ID 和 Bundle ID 动态替换。校验不验证苹果信任链。尚未进行真实账号联机测试。不要提交私钥、证书或描述文件。
