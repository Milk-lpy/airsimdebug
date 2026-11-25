# AirSIM Developer Capability Setup

交互式配置 Apple Developer Bundle ID，并校验原模板的 24 项签名授权字段。

## 使用
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

## 限制
官方 API 仅尝试启用脚本 CAPS 列出的能力。默认通信权限、内存增强权限、通信通知等需后台操作或苹果审批。App Groups 需人工创建和关联，原模板五个组名可能不适用于其他团队。iCloud 与 Apple 登录可能需要额外配置。校验模板位于 setup.py 的 EXPECTED，Team ID 和 Bundle ID 动态替换。校验不验证苹果信任链。尚未进行真实账号联机测试。不要提交私钥、证书或描述文件。
