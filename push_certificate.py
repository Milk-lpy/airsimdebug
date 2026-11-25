#!/usr/bin/env python3
"""生成用于 Apple 开发者后台的 CSR，并将签发的推送证书导出为 P12。"""
import argparse
from datetime import datetime, timezone
import getpass
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import warnings

PORTAL = "https://developer.apple.com/account/resources/certificates/add"
KINDS = ("apns", "voip")
LABELS = {
    "apns": "Apple Push Notification service SSL (Sandbox & Production)",
    "voip": "VoIP Services Certificate",
}
DEFAULT_STORE = Path.home() / ".airsim-push"


class InputError(ValueError):
    """可由用户修正的输入或文件状态。"""


def arguments(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command")
    csr = commands.add_parser("csr", help="生成或恢复证书签名请求")
    export = commands.add_parser("export", help="将下载的 CER 和原私钥导出为 P12")
    for command in (csr, export):
        command.add_argument("--bundle", help="显式 Bundle ID，例如 com.example.app")
        command.add_argument("--store", type=Path, default=DEFAULT_STORE,
                             help="密钥根目录（默认 ~/.airsim-push）")
    csr.add_argument("--type", choices=(*KINDS, "both"), help="证书类型，both 生成两组独立密钥")
    csr.add_argument("--email", help="写入新 CSR 的联系邮箱")
    export.add_argument("--type", choices=KINDS, help="用于查找原私钥的证书类型")
    export.add_argument("--certificate", type=Path, help="从 Apple 后台下载的 DER 或 PEM 证书")
    export.add_argument("--key", type=Path, help="原始 PEM 私钥（未加密），默认使用所选类型的 private.key")
    export.add_argument("--output", type=Path, help="P12 目标路径，旁边同时保存同名 PEM")
    export.add_argument("--confirm-topics", action="store_true",
                        help="跳过人工确认提示，表示你已核对证书类型、App ID 及推送主题；仍检查密钥、有效期和目标主题")
    export.add_argument("--password-stdin", action="store_true",
                        help="从非终端标准输入读取一行 P12 密码，需提供所有参数并确认主题")
    return parser.parse_args(argv)


def prompt_bundle(bundle):
    bundle = bundle if bundle is not None else input("请输入 App 的 Bundle ID：").strip()
    if not re.fullmatch(r"[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+", bundle):
        raise InputError("请输入显式 Bundle ID，例如 com.example.app。")
    return bundle


def interactive_args():
    bundle = prompt_bundle(None)
    print("1 生成 APNs CSR    2 生成 VoIP CSR    3 两者都生成    4 从 CER 导出 P12")
    choice = input("请选择 [1/2/3/4]：").strip()
    if choice in ("1", "2", "3"):
        return arguments(["csr", "--bundle", bundle, "--type", {"1": "apns", "2": "voip", "3": "both"}[choice]])
    if choice == "4":
        return arguments(["export", "--bundle", bundle])
    raise InputError("请输入 1、2、3 或 4。")


def choose_kind(kind, allow_both=False):
    choices = (*KINDS, "both") if allow_both else KINDS
    if kind is None:
        kind = input(f"证书类型 [{' / '.join(choices)}]：").strip().lower()
    if kind not in choices:
        raise InputError("请选择 " + " / ".join(choices))
    return kind


def publish(path, data):
    """Atomically publish a complete mode-0600 file. Never replace a winner."""
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    fd, name = tempfile.mkstemp(dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as staged:
            staged.write(data)
        try:
            os.link(name, path)
            return True
        except FileExistsError:
            return False
    finally:
        os.unlink(name)


def load_key(path):
    from cryptography.hazmat.primitives.serialization import load_pem_private_key

    try:
        return load_pem_private_key(path.read_bytes(), password=None)
    except (TypeError, ValueError) as exc:
        raise InputError(f"无法读取私钥 {path}。请恢复原私钥，或用新的 --store 目录申请证书。") from exc


def public_bytes(key):
    from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat
    return key.public_bytes(Encoding.DER, PublicFormat.SubjectPublicKeyInfo)


def generate_csr(directory, bundle, kind, email):
    from cryptography import x509
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import rsa
    from cryptography.x509.oid import NameOID

    key_path = directory / "private.key"
    csr_path = directory / "request.csr"
    # A CSR common name is a descriptive label and has a 64-character limit.
    label = f"{bundle} {kind}" if len(bundle) + len(kind) < 64 else f"{kind} {bundle}"[:64]
    subject = [x509.NameAttribute(NameOID.COMMON_NAME, label)]
    if email:
        if not re.fullmatch(r"[^\s@]+@[^\s@]+", email) or not email.isascii():
            raise InputError("--email 需要有效的 ASCII 邮箱地址。")
        subject.append(x509.NameAttribute(NameOID.EMAIL_ADDRESS, email))

    if not key_path.exists():
        if any(directory.glob("*.p12")) or csr_path.exists() or (directory / "certificate.pem").exists():
            raise InputError(f"{directory} 有现存证书文件但缺少 private.key。请恢复原私钥，或用新的 --store 重新申请。")
        key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
        publish(key_path, key.private_bytes(serialization.Encoding.PEM,
                                           serialization.PrivateFormat.PKCS8,
                                           serialization.NoEncryption()))
    key = load_key(key_path)
    if not csr_path.exists():
        csr = x509.CertificateSigningRequestBuilder().subject_name(x509.Name(subject)).sign(key, hashes.SHA256())
        publish(csr_path, csr.public_bytes(serialization.Encoding.PEM))

    try:
        csr = x509.load_pem_x509_csr(csr_path.read_bytes())
        if not csr.is_signature_valid or public_bytes(csr.public_key()) != public_bytes(key.public_key()):
            raise ValueError("CSR 与私钥不匹配")
    except ValueError as exc:
        raise InputError(f"现有 CSR 无效或与私钥不匹配：{csr_path}。请恢复匹配的文件，或使用新的 --store。") from exc
    if email and x509.NameAttribute(NameOID.EMAIL_ADDRESS, email) not in csr.subject:
        raise InputError("现有 CSR 的联系邮箱与 --email 不同。请保留原文件并用新的 --store 生成。")
    print(f"{LABELS[kind]}\n  上传 CSR：{csr_path}\n  私钥保存在：{key_path}")


def load_cert(path):
    from cryptography import x509
    data = path.read_bytes()
    try:
        if data.lstrip().startswith(b"-----BEGIN"):
            return x509.load_pem_x509_certificate(data)
        return x509.load_der_x509_certificate(data)
    except ValueError as exc:
        raise InputError(f"无法读取证书 {path}，请使用从 Apple 后台下载的 DER 或 PEM 格式证书。") from exc


def declared_topics(cert):
    """Read full ASN.1 string values from Apple provider-certificate extensions."""
    from cryptography import x509
    from cryptography.x509.oid import ObjectIdentifier

    topics = set()
    for oid in ("1.2.840.113635.100.6.3.4", "1.2.840.113635.100.6.3.6"):
        try:
            extension = cert.extensions.get_extension_for_oid(ObjectIdentifier(oid))
        except x509.ExtensionNotFound:
            continue
        der = extension.value.value
        try:
            parsed = subprocess.run(["openssl", "asn1parse", "-inform", "DER"],
                                    input=der, capture_output=True, check=True)
        except (OSError, subprocess.CalledProcessError) as exc:
            raise InputError(f"无法解析主题扩展 {oid}。请检查 OpenSSL 安装和下载的 CER。") from exc
        # Offsets identify the actual bytes of each ASN.1 value. Apple's nested
        # sequences include topic strings and short labels such as “app”.
        for line in parsed.stdout.splitlines():
            match = re.match(rb"^\s*(\d+):d=\d+\s+hl=\s*(\d+)\s+l=\s*(\d+)\s+prim:\s*(?:UTF8STRING|IA5STRING|PRINTABLESTRING)\s*:", line)
            if match:
                offset, header, size = map(int, match.groups())
                value = der[offset + header:offset + header + size]
                if re.fullmatch(rb"[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+", value):
                    topics.add(value.decode("ascii"))
    return topics


def primary_apns_topic(cert):
    """Legacy single-topic certificates expose the app topic in their CN."""
    from cryptography.x509.oid import NameOID

    for cn in cert.subject.get_attributes_for_oid(NameOID.COMMON_NAME):
        match = re.fullmatch(r"Apple (?:(?:Development|Production) IOS )?Push Services: (.+)",
                             cn.value, re.IGNORECASE)
        if match:
            return match.group(1)
    return None


def inspect_certificate(cert, key, bundle, kind):
    from cryptography.x509.oid import NameOID

    if public_bytes(cert.public_key()) != public_bytes(key.public_key()):
        raise InputError("证书与原私钥不匹配。请核对 --bundle、--type、--store 及下载的 CER。")
    now = datetime.now(timezone.utc)
    if not cert.not_valid_before_utc <= now <= cert.not_valid_after_utc:
        raise InputError(f"证书当前不在有效期内：{cert.not_valid_before_utc} 至 {cert.not_valid_after_utc}")
    print(f"期望的 App ID 和证书类型：{bundle} / {LABELS[kind]}")
    print(f"证书主题：{cert.subject.rfc4514_string()}\n签发者：{cert.issuer.rfc4514_string()}\n有效至：{cert.not_valid_after_utc}")
    topic = bundle + ".voip" if kind == "voip" else bundle
    print(f"请核对目标推送主题（topic）：{topic}")
    topics = declared_topics(cert)
    if topics:
        print("证书声明的推送主题：" + "、".join(sorted(topics)))
    if topic not in topics and not (kind == "apns" and primary_apns_topic(cert) == topic):
        raise InputError(f"证书未声明所需的推送主题 {topic}。请核对 Bundle ID 和证书类型，必要时重新申请证书。")
    identities = cert.subject.get_attributes_for_oid(NameOID.USER_ID)
    # Provider certificates can include a topic suffix in the identity.
    accepted = {bundle, topic}
    if identities and not any(uid.value in accepted for uid in identities):
        raise InputError("证书主题 UID 与指定 Bundle ID 不符。请核对证书文件和 --bundle。")


def password_for_export(stdin):
    if stdin:
        if sys.stdin.isatty():
            raise InputError("--password-stdin 需要管道输入，交互使用时请省略此选项。")
        password = sys.stdin.buffer.readline().removesuffix(b"\n").removesuffix(b"\r")
    else:
        with warnings.catch_warnings():
            warnings.simplefilter("error", getpass.GetPassWarning)
            try:
                password = getpass.getpass("设置或输入 P12 密码：").encode()
                if password != getpass.getpass("请再次输入密码：").encode():
                    raise InputError("两次密码不同。")
            except getpass.GetPassWarning as exc:
                raise InputError("无法关闭密码回显。请在交互终端运行，或从受保护的管道配合 --password-stdin。") from exc
    if not password or any(x in password for x in (b"\0", b"\r", b"\n")) or len(password) > 1023:
        raise InputError("P12 密码需要 1 至 1023 字节，不可包含换行或空字符。")
    return password


def export_cert(args, store, bundle, kind):
    from cryptography.hazmat.primitives import serialization
    from cryptography.hazmat.primitives.serialization import pkcs12

    directory = store / bundle / kind
    key_path = args.key.expanduser() if args.key else directory / "private.key"
    if not key_path.is_file():
        raise InputError(f"缺少签发该证书时使用的原私钥：{key_path}。请通过 --key 指向原始 PEM 私钥，或恢复备份。")
    key = load_key(key_path)
    cer = args.certificate or Path(input("从 Apple 后台下载的 CER 路径：").strip())
    cert = load_cert(cer.expanduser())
    inspect_certificate(cert, key, bundle, kind)
    if not args.confirm_topics and input("已核对证书类型、App ID 和推送主题？输入 YES 继续：").strip() != "YES":
        raise InputError("已取消导出。")
    output = args.output.expanduser() if args.output else directory / f"{kind}.p12"
    if output.suffix.lower() not in (".p12", ".pfx"):
        raise InputError("--output 应以 .p12 或 .pfx 结尾。")
    pem = output.with_suffix(".pem") if args.output else directory / "certificate.pem"
    cert_bytes = cert.public_bytes(serialization.Encoding.PEM)
    if pem.exists() and load_cert(pem) != cert:
        raise InputError(f"已有不同证书：{pem}。请通过 --output 指定其他文件名。")
    password = password_for_export(args.password_stdin)
    if not output.exists():
        encoded = pkcs12.serialize_key_and_certificates(
            f"{bundle} {kind}".encode(), key, cert, None, serialization.BestAvailableEncryption(password))
        publish(output, encoded)
    try:
        existing_key, existing_cert, _ = pkcs12.load_key_and_certificates(output.read_bytes(), password)
        if existing_key is None or existing_cert != cert or public_bytes(existing_key.public_key()) != public_bytes(key.public_key()):
            raise ValueError("P12 内容不匹配")
    except ValueError as exc:
        raise InputError(f"已有 P12 的密码或内容不符：{output}。请使用原密码，或用 --output 指定其他文件名。") from exc
    if not publish(pem, cert_bytes) and load_cert(pem) != cert:
        raise InputError(f"目标 PEM 已被其他证书占用：{pem}。请使用新的 --output。")
    print(f"已核对 P12 中的证书和密钥：{output}\nPEM 证书：{pem}")
    print("本地校验覆盖密钥匹配、有效期及 P12 密码。Apple 信任链和实际推送需在部署环境验证。")


def main(argv=None):
    args = arguments(argv)
    if not args.command:
        args = interactive_args()
    if args.command == "export" and args.password_stdin and not all(
            (args.bundle, args.type, args.certificate, args.confirm_topics)):
        raise InputError("--password-stdin 需要同时指定 --bundle、--type、--certificate 和 --confirm-topics。")
    bundle = prompt_bundle(args.bundle)
    kind = choose_kind(args.type, allow_both=args.command == "csr")
    store = args.store.expanduser()
    if args.command == "export":
        export_cert(args, store, bundle, kind)
        return
    for item in KINDS if kind == "both" else (kind,):
        generate_csr(store / bundle / item, bundle, item, args.email)
    print(f"在 Apple 开发者后台选择上面对应的证书类型及 App ID，上传 request.csr 并下载 CER。\n{PORTAL}")
    print("下载后运行 python3 push_certificate.py export，按提示将 CER 导出为 P12。")


if __name__ == "__main__":
    os.umask(0o077)
    try:
        main()
    except (KeyboardInterrupt, EOFError):
        sys.exit("已取消。")
    except ModuleNotFoundError as exc:
        if exc.name != "cryptography":
            raise
        sys.exit("请先运行 python3 -m pip install -r requirements.txt 安装证书依赖。")
    except (OSError, ValueError) as exc:
        sys.exit(str(exc))
