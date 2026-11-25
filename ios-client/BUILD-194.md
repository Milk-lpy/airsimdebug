# 在 Mac 上构建 AirSIM iOS 194 通用版

此版本基于 Dot 交付的 AirSIM 0.9.9（194）源码，包含 iPhone 主 App、Live Activity、通知服务扩展和 Watch App。通用版启动后在 AirSIM 设置中填写自己的 HTTPS Relay。默认配置已清除家庭 Relay 地址、家庭 HTTP 例外和指定安卓设备的宽带音频试验标识。

在 Apple Silicon Mac 上准备 Xcode 27.2、iOS 与 watchOS SDK。从包含本文的目录运行以下两条命令。工程文件保留基础 build 193，归档时将各目标覆盖为 194。Release 配置使用 APNs Sandbox。

```bash
xcodebuild -project iOS/AirSIM.xcodeproj -scheme AirSIM -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$PWD/AirSIM-194.xcarchive" \
  MARKETING_VERSION=0.9.9 CURRENT_PROJECT_VERSION=194 \
  APS_ENVIRONMENT=development AIRSIM_APNS_ENVIRONMENT=sandbox \
  CODE_SIGNING_ALLOWED=NO archive

sh iOS/scripts/package-unsigned.sh "$PWD/AirSIM-194.xcarchive" \
  "$PWD/AirSIM-iOS-0.9.9-build194-Sandbox-full-unsigned.ipa" full
```

默认主 App Bundle ID 为 `com.heroxhs.airsim`。安装未签名 IPA 前，需要使用有相应权限的身份给主 App、两个扩展和 Watch App 一起签名。重新签名时，App 的推送权限、设备 Token、Relay 的 APNs 环境和获准的 Topic 需要匹配。使用自己的 Bundle ID 时，还要相应调整嵌入目标、App Groups 和配套描述文件。首次验证请用真机分别测试来电和短信。

自建环境可通过 Xcode 构建设置 `AIRSIM_PUSH_RELAY_URL` 预填入口。宽带音频试验如需指定自己的安卓网关，可设置 `AIRSIM_WIDEBAND_TRIAL_AGENT_ID`。
