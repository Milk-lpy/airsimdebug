#!/usr/bin/env python3
"""配置 AirSIM 的 Apple Developer 能力并校验开发描述文件。"""
import argparse
import base64
import binascii
import os
import plistlib
import re
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import urlsplit

API_ROOT = "https://api.appstoreconnect.apple.com/v1/"
PORTAL = "https://developer.apple.com/account/resources/identifiers/list"
CAPS = (
    "PUSH_NOTIFICATIONS", "ASSOCIATED_DOMAINS", "AUTOFILL_CREDENTIAL_PROVIDER",
    "APP_GROUPS", "ICLOUD", "APPLE_ID_AUTH",
)
DEFAULT_GROUPS = [f"group.songzixy.example{i}" for i in range(1, 6)]


def expected_entitlements(bundle, team, prefix, groups):
    return {
        "com.apple.developer.dialing-app": True,
        "com.apple.security.application-groups": groups,
        "com.apple.developer.calling-app": True,
        "com.apple.developer.associated-domains": "*",
        "com.apple.developer.authentication-services.autofill-credential-provider": True,
        "com.apple.developer.messaging-app": True,
        "application-identifier": f"{prefix}.{bundle}",
        "keychain-access-groups": [prefix + ".*", "com.apple.token"],
        "get-task-allow": True,
        "com.apple.developer.team-identifier": team,
        "com.apple.developer.ubiquity-kvstore-identifier": team + ".*",
        "com.apple.developer.icloud-services": "*",
        "com.apple.developer.icloud-container-identifiers": [],
        "com.apple.developer.icloud-container-development-container-identifiers": [],
        "com.apple.developer.usernotifications.communication": True,
        "com.apple.developer.kernel.increased-debugging-memory-limit": True,
        "com.apple.developer.ubiquity-container-identifiers": [],
        "com.apple.developer.usernotifications.time-sensitive": True,
        "com.apple.developer.kernel.increased-memory-limit": True,
        "aps-environment": "development",
        "com.apple.developer.icloud-extended-share-access": [
            "InProcessShareAccessRequests", "InProcessShareOwnerParticipantInfo", "InProcessOneTimeLinks",
        ],
        "com.apple.developer.carrier-messaging-app": True,
        "com.apple.developer.kernel.extended-virtual-addressing": True,
        "com.apple.developer.applesignin": ["Default"],
    }


class WorkflowError(Exception):
    """Error with a user-facing recovery message."""


class AppleError(WorkflowError):
    def __init__(self, status, message):
        super().__init__(message)
        self.status = status


def explicit_id(value):
    if not re.fullmatch(r"[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+", value):
        raise argparse.ArgumentTypeError("请输入显式 Bundle ID，例如 com.example.airsim")
    return value


def apple_id(value):
    if not re.fullmatch(r"[A-Z0-9]{10}", value):
        raise argparse.ArgumentTypeError("Team ID 和 App ID prefix 应为 10 位大写字母或数字")
    return value


def requested_value(value, prompt, flag, validate):
    if value:
        return value
    if not sys.stdin.isatty():
        raise WorkflowError(f"请通过 {flag} 提供{prompt}")
    while True:
        try:
            return validate(input(f"{prompt}：").strip())
        except argparse.ArgumentTypeError as exc:
            print(exc, file=sys.stderr)


def cli():
    parser = argparse.ArgumentParser(description=__doc__, epilog="默认离线预览；账号写操作需要输入 YES。")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--apply", action="store_true", help="启用能力，可选创建 iOS 开发描述文件")
    mode.add_argument("--verify", type=Path, metavar="FILE", help="校验本地 mobileprovision 文件")
    mode.add_argument("--list-resources", action="store_true", help="从 Apple 读取开发证书和已启用设备的资源 ID")
    parser.add_argument("--capability", action="append", choices=CAPS,
                        help="仅尝试启用指定能力，可重复；默认使用全部六项")
    parser.add_argument("--bundle", type=explicit_id, help="目标 Bundle ID")
    parser.add_argument("--team-id", type=apple_id, help="校验时使用独立提供的 Apple Team ID")
    parser.add_argument("--app-id-prefix", type=apple_id, help="旧账号的 App ID prefix（默认与 Team ID 相同）")
    parser.add_argument("--app-group", action="append", help="使用自己团队的 App Group 替换模板组，可重复")
    parser.add_argument("--ca-file", type=Path, help="使用指定的 PEM CA 文件额外校验 CMS 签名链")
    parser.add_argument("--certificate", metavar="ID", help="开发签名证书资源 ID（见 --list-resources）")
    parser.add_argument("--device", action="append", metavar="ID", help="设备资源 ID，可重复（见 --list-resources）")
    parser.add_argument("--profile-name", help="Apple 后台的描述文件名称")
    parser.add_argument("--output", type=Path, help="写入新文件，默认 <Bundle ID>.mobileprovision")
    return parser


def arguments(argv):
    parser = cli()
    args = parser.parse_args(argv)
    if bool(args.certificate) != bool(args.device):
        parser.error("--certificate 和 --device 需要一起提供，可通过 --list-resources 查看")
    if args.output or args.profile_name:
        if not args.certificate:
            parser.error("--output 和 --profile-name 仅适用于创建描述文件，请提供 --certificate 和 --device")
    if (args.verify or args.list_resources) and args.certificate:
        parser.error("创建描述文件的参数不能与只读模式混用")
    if args.capability and (args.verify or args.list_resources):
        parser.error("--capability 用于预览或 --apply")
    if not args.verify and (args.team_id or args.ca_file or args.app_id_prefix):
        parser.error("--team-id、--ca-file 和 --app-id-prefix 适用于 --verify")
    if args.app_group and any(not re.fullmatch(r"group(?:\.[A-Za-z0-9-]+)+", g) for g in args.app_group):
        parser.error("--app-group 需要 group. 开头的完整组名")
    if args.app_group and args.capability and "APP_GROUPS" not in args.capability:
        parser.error("指定 --app-group 时请同时选择 --capability APP_GROUPS")
    if args.list_resources and (args.bundle or args.app_group):
        parser.error("--list-resources 会列出当前团队资源，无需提供 Bundle ID 或 App Groups")
    return args


def read_profile(path, ca_file):
    opts = ["-noverify"]
    try:
        if ca_file:
            opts = ["-CAfile", str(ca_file), "-no-CApath", "-purpose", "any"]
            help_text = subprocess.run(["openssl", "cms", "-help"], stdout=subprocess.PIPE,
                                       stderr=subprocess.STDOUT).stdout
            if b"-no-CAstore" in help_text:  # OpenSSL 3 added the default URI trust store.
                opts.append("-no-CAstore")
        result = subprocess.run(["openssl", "cms", "-verify", "-inform", "DER", "-in",
                                 str(path), *opts], capture_output=True)
    except FileNotFoundError as exc:
        raise WorkflowError("请安装支持 cms 的 OpenSSL 并检查 PATH") from exc
    if result.returncode:
        detail = result.stderr.decode(errors="replace").strip().splitlines()
        raise WorkflowError(f"无法读取或验证 CMS 描述文件 {path}：{detail[-1] if detail else 'OpenSSL 验证失败'}")
    try:
        profile = plistlib.loads(result.stdout)
    except (ValueError, plistlib.InvalidFileException) as exc:
        raise WorkflowError("CMS 内容不是有效的描述文件 plist") from exc
    if not isinstance(profile, dict) or not isinstance(profile.get("Entitlements"), dict):
        raise WorkflowError("描述文件缺少 Entitlements 字典")
    return profile


def check_profile(profile, bundle, team, prefix, groups, now):
    expected = expected_entitlements(bundle, team, prefix, groups)
    expiration = profile.get("ExpirationDate")
    if isinstance(expiration, datetime) and expiration.tzinfo is None:
        expiration = expiration.replace(tzinfo=timezone.utc)
    checks = [
        ("ExpirationDate", isinstance(expiration, datetime) and expiration > now,
         f"截至 {expiration}，需晚于当前时间"),
        ("TeamIdentifier", isinstance(profile.get("TeamIdentifier"), list) and team in profile["TeamIdentifier"], team),
        ("ApplicationIdentifierPrefix", isinstance(profile.get("ApplicationIdentifierPrefix"), list)
         and prefix in profile["ApplicationIdentifierPrefix"], prefix),
    ]
    for key, wanted in expected.items():
        actual = profile["Entitlements"].get(key)
        if isinstance(wanted, list):
            matches = (isinstance(actual, list) and all(isinstance(x, str) for x in actual)
                       and sorted(actual) == sorted(wanted))
        else:
            matches = type(actual) is type(wanted) and actual == wanted
        checks.append((key, matches, f"期望 {wanted!r}，实际 {actual!r}"))
    for key, matches, detail in checks:
        print(f"通过 {key}" if matches else f"差异 {key}：{detail}")
    failures = sum(not ok for _, ok, _ in checks)
    print(f"已对照原始模板的 {len(expected)} 项授权字段；全部检查中有 {failures} 项差异")
    return int(bool(failures))


class AppleAPI:
    def __init__(self):
        names = ("ASC_KEY_PATH", "ASC_KEY_ID", "ASC_ISSUER_ID")
        missing = [k for k in names if not os.environ.get(k)]
        if missing:
            raise WorkflowError("使用 App Store Connect 团队 API 密钥并设置 " + "、".join(missing))
        try:
            import jwt
            import requests
        except ImportError as exc:
            raise WorkflowError("请先运行 python3 -m pip install -r requirements.txt") from exc
        self.jwt = jwt
        self.requests = requests
        self.key = Path(os.environ["ASC_KEY_PATH"]).expanduser().read_bytes()
        self.key_id = os.environ["ASC_KEY_ID"]
        self.issuer = os.environ["ASC_ISSUER_ID"]

    def request(self, method, url, params=None, body=None):
        now = int(time.time())
        try:
            token = self.jwt.encode({"iss": self.issuer, "iat": now, "exp": now + 600,
                                     "aud": "appstoreconnect-v1"}, self.key, algorithm="ES256",
                                    headers={"kid": self.key_id, "typ": "JWT"})
        except (self.jwt.PyJWTError, ValueError, TypeError) as exc:
            raise WorkflowError("无法使用 ES256 签名，请检查 ASC_KEY_PATH 指向有效的团队 API 私钥") from exc
        try:
            response = self.requests.request(method, url, params=params, json=body,
                                             headers={"Authorization": "Bearer " + token},
                                             timeout=40, allow_redirects=False)
        except self.requests.RequestException as exc:
            message = "请检查网络连接"
            if method == "POST":
                message += "；请求结果未知，重试前请在 Apple 后台核对已创建的资源"
            raise WorkflowError(f"{method} {urlsplit(url).path}：{message}") from exc
        try:
            document = response.json()
        except ValueError:
            document = {}
        if not 200 <= response.status_code < 300:
            errors = document.get("errors", []) if isinstance(document, dict) else []
            details = ", ".join(str(e.get("detail") or e.get("title") or e.get("code"))
                                for e in errors if isinstance(e, dict))
            hints = {401: "请检查团队密钥、Key ID、Issuer ID 与系统时间", 403: "请检查团队角色与开发者资源权限",
                     429: "请求过于频繁，请稍后再试"}
            raise AppleError(response.status_code, f"{method} {urlsplit(url).path} 返回 HTTP {response.status_code}。"
                             + " ".join(filter(None, (details, hints.get(response.status_code)))))
        if not isinstance(document, dict) or "data" not in document:
            raise WorkflowError("Apple 返回了无法识别的资源格式")
        return document

    def list(self, path, **filters):
        url = API_ROOT + path
        params = {"limit": 200, **filters}
        while url:
            document = self.request("GET", url, params=params)
            yield from document["data"]
            url = document.get("links", {}).get("next")
            if url and not url.startswith(API_ROOT):
                raise WorkflowError("Apple 返回了非预期的分页地址")
            params = None

    def create(self, resource, attributes, relationships=None):
        data = {"type": resource, "attributes": attributes}
        if relationships:
            data["relationships"] = relationships
        return self.request("POST", API_ROOT + resource, body={"data": data})["data"]


def list_resources(api):
    print("开发签名证书（资源 ID / 名称 / 到期时间）")
    certs = api.list("certificates", **{"filter[certificateType]": "DEVELOPMENT,IOS_DEVELOPMENT",
                                        "fields[certificates]": "displayName,expirationDate"})
    for cert in certs:
        attrs = cert["attributes"]
        print(cert["id"], attrs.get("displayName", ""), attrs.get("expirationDate", ""))
    print("已启用的 iOS 设备（资源 ID / 名称）")
    for device in api.list("devices", **{"filter[platform]": "IOS", "filter[status]": "ENABLED",
                                         "fields[devices]": "name"}):
        print(device["id"], device["attributes"].get("name", ""))


def relation(kind, resource_id):
    return {"type": kind, "id": resource_id}


def configure(api, bundle, capabilities=CAPS):
    bundles = list(api.list("bundleIds", **{"filter[identifier]": bundle,
                                            "filter[platform]": "IOS,UNIVERSAL"}))
    if len(bundles) > 1:
        raise WorkflowError("找到多个匹配的 iOS Bundle ID，请在 Apple 后台核对")
    target = bundles[0] if bundles else api.create("bundleIds", {"identifier": bundle, "name": bundle, "platform": "IOS"})
    bid = target["id"]
    caps = {row["attributes"]["capabilityType"] for row in api.list(f"bundleIds/{bid}/bundleIdCapabilities")}
    manual = []
    for cap in capabilities:
        if cap in caps:
            print("已启用", cap)
            continue
        try:
            api.create("bundleIdCapabilities", {"capabilityType": cap}, {"bundleId": {"data": relation("bundleIds", bid)}})
            print("已添加", cap)
        except AppleError as exc:
            if exc.status not in (400, 409, 422):
                raise
            print(f"{cap}：{exc}", file=sys.stderr)
            manual.append(cap)
    if manual:
        raise WorkflowError("请在 Apple 后台检查 " + "、".join(manual) + "；配置后可重跑以跳过已启用项")
    return bid


def save_profile(api, args, bid, output, staged):
    relationships = {
        "bundleId": {"data": relation("bundleIds", bid)},
        "certificates": {"data": [relation("certificates", args.certificate)]},
        "devices": {"data": [relation("devices", d) for d in dict.fromkeys(args.device)]},
    }
    name = args.profile_name or f"AirSIM {args.bundle} Development"
    profile = api.create("profiles", {"name": name, "profileType": "IOS_APP_DEVELOPMENT"}, relationships)
    print(f"Apple 已创建描述文件 {name}（资源 ID {profile['id']}）")
    try:
        content = base64.b64decode(profile["attributes"]["profileContent"], validate=True)
        if not content:
            raise ValueError("empty")
        staged.write(content)
        staged.flush()
        os.fsync(staged.fileno())
        os.link(staged.name, output)
    except (KeyError, TypeError, binascii.Error, ValueError, OSError) as exc:
        raise WorkflowError(f"未能保存到 {output}。请在 Apple 后台下载上面的已创建描述文件。") from exc
    print(f"已保存 {output}，可使用 --verify、--bundle 和 --team-id 校验")


def confirm(prompt):
    if input(prompt + "（输入 YES 继续）：").strip() != "YES":
        raise WorkflowError("已取消此操作")


def main(argv=None):
    args = arguments(argv)
    if args.list_resources:
        list_resources(AppleAPI())
        return 0
    args.bundle = requested_value(args.bundle, "目标 Bundle ID", "--bundle", explicit_id)
    groups = args.app_group or DEFAULT_GROUPS
    if args.verify:
        team = requested_value(args.team_id, "目标 Team ID", "--team-id", apple_id)
        profile = read_profile(args.verify, args.ca_file)
        print("已按指定 CA 校验 CMS 签名链" if args.ca_file else "已校验 CMS 签名完整性。使用 --ca-file 可校验签名链。")
        return check_profile(profile, args.bundle, team, args.app_id_prefix or team, groups, datetime.now(timezone.utc))

    capabilities = tuple(dict.fromkeys(args.capability or CAPS))
    print(f"目标 Bundle ID：{args.bundle}\nAPI 能力：" + "、".join(capabilities))
    if "APP_GROUPS" in capabilities:
        if not args.app_group:
            print("以下为原模板的示例组；可用 --app-group 指定团队自己的组。")
        print("请在 Apple 后台关联 App Groups：" + "、".join(groups))
    if "ICLOUD" in capabilities:
        print("请在 Apple 后台选择 iCloud 配置，并关联 App 所需的容器。")
    if "APPLE_ID_AUTH" in capabilities:
        print("请在 Apple 后台确认 Sign in with Apple 的主 App ID 或分组。")
    if not args.capability:
        print("完整模板还包含默认通话、拨号、消息、运营商消息、通信通知、时效性通知、"
              "内存与地址空间、iCloud Extended Share Access 授权。请按账号资格申请或配置。")
    print(PORTAL)
    output = (args.output or Path(f"{args.bundle}.mobileprovision")).expanduser()
    if args.certificate:
        print(f"描述文件：证书 {args.certificate}，设备 {', '.join(args.device)}，写入 {output}")
    if not args.apply:
        print("预览完成。添加 --apply 可应用配置。")
        return 0
    if args.certificate and os.path.lexists(output):
        raise WorkflowError(f"目标文件已存在：{output}。请用 --output 指定新文件")
    if args.certificate and not output.parent.is_dir():
        raise WorkflowError(f"请先创建输出目录 {output.parent}")
    api = AppleAPI()
    confirm(f"为 {args.bundle} 在团队 Issuer {api.issuer} 中应用上述能力？")
    if args.certificate:
        with tempfile.NamedTemporaryFile(dir=output.parent, prefix=".airsim-profile-") as staged:
            bid = configure(api, args.bundle, capabilities)
            confirm("已完成后台授权配置，使用上述证书和设备创建开发描述文件？")
            save_profile(api, args, bid, output, staged)
    else:
        configure(api, args.bundle, capabilities)
        print("能力配置完成。可使用 --list-resources 选择证书和设备，再生成描述文件。")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (KeyboardInterrupt, EOFError):
        sys.exit("已取消；已完成的 Apple 后台操作会保留。")
    except (OSError, WorkflowError) as err:
        sys.exit(str(err))
