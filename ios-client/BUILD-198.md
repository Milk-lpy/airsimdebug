# AirSIM iOS 0.9.9（198）

本版使用 AirSIM 安卓网关拨打电话和收发短信。拨号盘保留 iPhone 系统选线和设备实际返回的本机线路。在「拨号 → 默认拨号线路」选择一条具体线路。往后拨号沿用这次选择，所选卡不可用时可以重新选择。

最近通话显示 AirSIM 已保存的记录。升级前已存入 App 的本机资料仍可查看。iOS 系统通话历史查询、运营商消息收发和历史导入入口已经移除。本版对外接收电话号码并进入拨号盘，安卓短信仍通过已配对的网关发送。

Relay 控制连接使用 HTTPS，云端媒体通过 WSS 连接 Relay 为本次通话提供的地址。服务器根据客户端和安卓网关声明的能力决定媒体协议。在仅 Wi-Fi 或仅蓝牙模式下，路由器只查询该模式允许的本地后端。

[完整未签名 IPA](../binaries/ios/AirSIM-iOS-0.9.9-build198-Sandbox-full-unsigned.ipa?raw=true) · [SHA-256](../binaries/ios/AirSIM-iOS-0.9.9-build198-Sandbox-full-unsigned.ipa.sha256) · [构建与测试命令](../.github/workflows/build-ios-198.yml)

公开完整包包括主 App、两项扩展和 Watch。个人设备安装需签名；每个保留的目标都要有匹配的描述文件。签名时主 App 保留 calling-app、dialing-app 和开发环境推送权限。
