# AirSIM iOS 0.9.9（195）通用版

195 在同一个拨号盘里提供安卓网关 SIM、iPhone 本机线路和「iPhone · 系统选线」。使用两张本机卡时，可以根据 iOS 返回的主号、副号或自定义线路名称选择。iPhone 本机通话和本机运营商消息由系统和运营商处理，安卓卡继续使用 AirSIM 的局域网或 Relay 通道。

## 构建与签名

在配有 Xcode 27.2、iOS SDK 和 watchOS SDK 的 Mac 上，从本说明所在的 `ios-client` 目录执行。每次构建使用空的输出位置。

```sh
xcodebuild -project iOS/AirSIM.xcodeproj -scheme AirSIM -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$PWD/AirSIM-195.xcarchive" \
  MARKETING_VERSION=0.9.9 CURRENT_PROJECT_VERSION=195 \
  APS_ENVIRONMENT=development AIRSIM_APNS_ENVIRONMENT=sandbox \
  AIRSIM_PUSH_RELAY_URL= AIRSIM_WIDEBAND_TRIAL_AGENT_ID= \
  CODE_SIGNING_ALLOWED=NO archive

sh iOS/scripts/package-unsigned.sh "$PWD/AirSIM-195.xcarchive" \
  "$PWD/AirSIM-iOS-0.9.9-build195-Sandbox-full-unsigned.ipa" full
```

生成的完整 IPA 包含 iPhone 主 App、通知服务扩展、Live Activity 扩展和 Watch App。建议用 Xcode 为这四个目标绑定同一开发团队下各自的 Bundle ID 和匹配的描述文件，再签名安装。使用自己的换签工具时，保留四个目标、各自的 App Groups、主从 Bundle ID 关系和推送环境。主 App 默认 Bundle ID 是 `com.heroxhs.airsim`。需要覆盖安装并保留本地数据时，核对团队和 App 身份与当前安装一致。

主 App 的签名和内嵌描述文件都需要下列四个布尔权限。用最终签名后的安装包在 Mac 上核对。脚本同时输出实际签入的 APNs 环境。该包的安卓来电推送按开发环境（Sandbox）构建，Relay 的 APNs 环境、设备 Token 和获准的 Topic 要与最终签名匹配。

```sh
sh iOS/scripts/check-default-calling-signature.sh --full "/path/to/AirSIM-195-signed.ipa"
```

| 主 App 权限 | 用途 |
| --- | --- |
| `com.apple.developer.calling-app` | 系统点电话号码时把目标号码交给 AirSIM |
| `com.apple.developer.dialing-app` | 通过 LiveCommunicationKit 指定 iPhone 蜂窝线路，并在成为默认拨号器后读取系统提供的近期记录 |
| `com.apple.developer.messaging-app` | 处理默认即时通信入口，预填收件人 |
| `com.apple.developer.carrier-messaging-app` | 被设为默认运营商消息 App 后，通过 iPhone 的可用线路收发 SMS、MMS、RCS |

## iPhone 设置

1. 在「设置 → 蜂窝网络」启用要使用的线路，并给双卡取容易区分的标签，例如「主号」「工作」。确认系统「电话」可以使用各线路拨出。
2. 打开「设置 → App → 默认 App」。在「通话」里，将发起通话以及拨打蜂窝电话的相应选项设为 AirSIM。在「信息」里，将发起消息以及收发运营商消息的相应选项设为 AirSIM。菜单名称和可用选项随系统版本、地区和设备资格而异。仅勾选普通通话或普通信息时，系统可以把号码交给 AirSIM，但运营商功能还需对应的默认角色。[Apple 默认 App 设置](https://support.apple.com/zh-cn/121430)
3. 打开一次 AirSIM，切到「短信」，允许本机消息通知。若要同时使用安卓卡，在 AirSIM 中完成安卓配对或配置自己的 HTTPS Relay。只测试本机卡可在首次引导中点「稍后在设置中配对」。
4. 本机逐卡拨号和运营商消息使用 iOS 26 起的接口。Apple 对默认拨号器真机测试要求开发者账号注册在欧盟、设备位于欧盟。对于运营商消息，Apple 另提供描述文件以在各地区开发测试；面向用户使用时，Apple 要求账号注册在欧盟且设备位于欧盟。最终签名的权限通过检查后，还需确认设备实际显示默认选项、返回线路，且运营商启用了所选协议。[默认拨号器条件](https://developer.apple.com/documentation/livecommunicationkit/preparing-your-app-to-be-the-default-dialer-app) · [TelephonyMessagingKit 条件](https://developer.apple.com/documentation/telephonymessagingkit)

## 首次实测

- **本机双卡和安卓卡。** 从系统通讯录点测试号码，确认 AirSIM 拨号盘显示原号码。分别选择「iPhone · 主号」「iPhone · 副号」后点绿色拨号，用收端来电显示核对外呼号码。接着选安卓 SIM，检查是否由安卓网关发起。关闭网关后，再选一条 iPhone 本机线路复测。若系统没有提供单独的线路，可以手动选「iPhone · 系统选线」，由系统确认并使用其线路策略。[Apple 默认通话 App 与蜂窝回退](https://developer.apple.com/documentation/callkit/preparing-your-app-to-be-the-default-calling-app)
- **新通话与回拨。** 成为默认拨号器后产生一通测试电话，检查「最近」里的方向、号码和时间，再从该记录回到拨号盘选卡。旧通话需要通过下方的历史导入查看。
- **本机短信。** 到「短信 → 新信息」，选明确的 iPhone 发件线路与 SMS。向另一部可控手机发送并回复，核对发件号码、收到的正文和锁屏提醒。分别在两条可用线路上重复。网关与本机的记录分开显示。
- **彩信与 RCS。** 选支持相应协议的 iPhone 线路，分别发送 MMS 图片、RCS 文本和 RCS 附件，并查收回复。RCS 附件和文本分开发送。加密 RCS 需 iOS 26.5 及以上，并取决于双方和运营商支持。如果对方只能收 SMS，手动选择合适的协议后发送。
- **安卓路径。** 验证原有来电、接听、双向音频、发送及接收短信。检查 iPhone 锁屏时的安卓来电系统界面。运营商本机通话和 AirSIM 的安卓 CallKit 推送应分别验证。

## 导入以前的短信和通话

在自己的电脑上准备已导出、解密的 `sms.db`、`CallHistory.storedata` 或其中一个。用随附的 Python 工具生成本地 JSON，传到 iPhone 的「文件」，在 AirSIM「短信 → iPhone 本机」选择历史导入并确认。工具支持显式选择同一快照的 WAL，以及按日期分包。重复导入同一来源时保留一份记录。[工具说明与示例](tools/README.md)

导入的消息用于本地只读查看，包含数据库中可解析的 iMessage 文本。若要查看旧彩信和 iMessage 附件，在导出时通过 `--attachments-dir` 选择同一快照的附件目录。每个文件最多 32 MB，单包最多 128 MB。缺失文件保留占位，之后补齐附件再导入时会并入原消息。系统默认信息入口用于预填地址，本机实时收发支持的是运营商可用的 SMS、MMS 和 RCS。[Apple 默认信息 App](https://developer.apple.com/documentation/messages/preparing-your-app-to-be-the-default-messaging-app) · [Apple 运营商消息接口](https://developer.apple.com/documentation/telephonymessagingkit)
