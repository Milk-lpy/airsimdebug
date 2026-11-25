# AirSIM 安卓客户端

公开通用版为 **0.9.8.27-home.12（153）**，包名为 `com.airsim.phonecontrol.standalone`，最低支持 Android 10。安装后，在首页「云 Relay 地址 → 编辑地址」填入手机能访问的 HTTPS 地址。只填局域网或隧道 IP 时，默认使用 HTTPS 18788 端口；完整 URL 按所填端口连接。「跟随 iPhone」可恢复使用配对设备同步的地址。

[下载已经签名的安卓 153 APK](../binaries/android/AirSIM-Android-153.apk)。发布包沿用家庭版的签名，覆盖安装可保留配对数据；通用版使用 Android 系统信任的证书。正在使用家庭私有 CA 的设备可继续使用现有家庭版，或使用下方步骤从源码构建适用于自己入口的版本。

## 在本地构建

准备 JDK 17、Android SDK Platform 35、Build Tools 35.0.0、Bash、curl、shasum、zip、unzip。设置 `JAVA_HOME` 和 `ANDROID_SDK_ROOT` 后，在本目录运行以下命令。首次构建会下载并按固定摘要验证依赖。

```sh
sh android-standalone/build.sh
```

调试包输出到 `android-standalone/build/android/AirSIM-Android-Standalone-debug.apk`。构建自签发布版时，将 `AIRSIM_ANDROID_BUILD_VARIANT` 设为 `release`，并提供 `AIRSIM_ANDROID_KEYSTORE`、`AIRSIM_ANDROID_KEY_ALIAS`、`AIRSIM_ANDROID_KEYSTORE_PASSWORD` 和 `AIRSIM_ANDROID_KEY_PASSWORD`。自行生成的签名用于新安装或覆盖同一签名的旧版本。

若需要自己的私网 CA，构建前设置 `AIRSIM_RELAY_LAN_IP`、`AIRSIM_RELAY_TUNNEL_IP` 与 `AIRSIM_RELAY_CA_FILE`，并准备 Python 3 和 OpenSSL。证书文件使用 PEM 格式的公开根证书。构建器将额外的信任限定到这两个私网地址。完整功能和构建参数见 [Standalone 说明](android-standalone/README.md)。

## 测试与许可

准备 Node.js、Android SDK 的 `apkanalyzer` 并将它们加入 PATH，在本目录运行 `sh android-standalone/test.sh`。测试覆盖 Relay 地址编辑、配对恢复、短信密钥与队列、VoWLAN 和云端通话等行为。真实通话和锁屏推送需在完成配对的设备上验证。

AirSIM 源自 [kai-wu-cortex/AirSIM](https://github.com/kai-wu-cortex/AirSIM)，按 [PolyForm Noncommercial 1.0.0](LICENSE) 分发，另见 [上游署名](NOTICE)和[第三方声明](THIRD_PARTY_NOTICES.md)。
