# AirSIM iOS 0.9.9（196）

此版本继续使用 APNs Sandbox，包含 iPhone 主 App、通知服务扩展、Live Activity 扩展和 Watch App。[下载未签名 IPA](../binaries/ios/AirSIM-iOS-0.9.9-build196-Sandbox-full-unsigned.ipa?raw=true) · [SHA-256](../binaries/ios/AirSIM-iOS-0.9.9-build196-Sandbox-full-unsigned.ipa.sha256)

## 双卡与默认线路

在「拨号 → 默认拨号线路」选择 iOS 返回的本机线路、iPhone 系统选线或已连接的安卓 SIM。指定线路后 AirSIM 会记住选择。打开选卡界面或重新回到前台时，App 会重新读取系统线路。原先指定的卡消失时，请重新选线。拨号盘里的偏好只对 AirSIM 生效。

短信页单独检查运营商消息角色、iOS 返回的短信线路和每条线路支持的协议。双卡手机可以在撰写消息时指定本机短信线路。手动选择的短信线路会单独保存。

## 查明记录为何没有出现

打开「设置 → 帮助与诊断 → 检查连接 → iPhone 通信自检」。最近通话读取失败时，也可从错误提示直接打开自检。自检显示通话线路数量、拨号偏好、运营商消息角色、短信线路数量，以及通话历史的查询结果或错误。它也分别检查当前安装包签名和内嵌描述文件中的四项默认通信权限。「复制自检结果」只复制版本、状态、计数及错误代码。

用设为默认拨号器后发生的一次 iPhone 蜂窝通话核对「最近 → 全部」。Apple 从默认拨号器开始生效的时间提供符合条件的通话记录。切换默认运营商短信 App 后，可用一条新的普通 SMS 验证收件。旧短信、iMessage 和更早通话可使用用户自己的本地备份迁移。[Apple 默认拨号器说明](https://developer.apple.com/documentation/livecommunicationkit/preparing-your-app-to-be-the-default-dialer-app) · [Apple 运营商消息说明](https://developer.apple.com/documentation/telephonymessagingkit/creating-a-carrier-messaging-app) · [本机导入工具及步骤](tools/)

## 签名与构建

覆盖安装请沿用原来的开发团队、App 身份和相匹配的描述文件，保留 App 本地数据。各目标的签名方法和权限表见 [195 签名说明](BUILD-195.md)。196 的完整归档、验证和测试命令见 [本版构建工作流](../.github/workflows/build-ios-196.yml)。真机上系统授予的角色及线路应以该设备的自检结果为准。自检中的签名字段用于区分描述文件授权与实际签入的权限。[Apple 签名与描述文件说明](https://developer.apple.com/documentation/technotes/tn3125-inside-code-signing-provisioning-profiles)
