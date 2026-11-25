"""Offline CLI tests for the CSR and PKCS#12 workflows (no Apple account)."""
import os
from datetime import datetime, timedelta, timezone
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.hazmat.primitives.serialization import pkcs12
from cryptography.x509.oid import NameOID


SCRIPT = Path(__file__).resolve().parents[1] / "push_certificate.py"
BUNDLE = "com.example.test"


class PushCertificateCLI(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.store = Path(self.tmp.name)
        self.directory = self.store / BUNDLE / "apns"
        self.key = self.directory / "private.key"
        self.csr = self.directory / "request.csr"
        self.cert_path = self.store / "test.cer"

    def cli(self, command, *options, data=b"", ok=True):
        args = [sys.executable, str(SCRIPT), command, "--bundle", BUNDLE,
                "--store", str(self.store), *map(str, options)]
        result = subprocess.run(args, input=data, capture_output=True)
        self.assertEqual(result.returncode == 0, ok, result.stderr.decode())
        return result

    def create(self):
        self.cli("csr", "--type", "apns")

    def issue(self, *, before=None, after=None, uid=BUNDLE, other_key=False, pem=False,
              topics=(), oid="1.2.840.113635.100.6.3.6", cn="Apple Push Services: " + BUNDLE):
        if other_key:
            key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
        else:
            key = serialization.load_pem_private_key(self.key.read_bytes(), None)
        name = x509.Name([x509.NameAttribute(NameOID.USER_ID, uid), x509.NameAttribute(NameOID.COMMON_NAME, cn)])
        now = datetime.now(timezone.utc)
        builder = (x509.CertificateBuilder().subject_name(name).issuer_name(name)
                .public_key(key.public_key()).serial_number(x509.random_serial_number())
                .not_valid_before(before or now - timedelta(days=1))
                .not_valid_after(after or now + timedelta(days=1)))
        if topics:
            # As in APNs universal certificates: UTF8 topic, then a sequence
            # of UTF8 type labels. These short fixtures use one-byte DER lengths.
            strings = b""
            for topic in topics:
                label = b"app" if topic == BUNDLE else topic.rsplit(".", 1)[-1].encode()
                strings += (bytes([0x0c, len(topic)]) + topic.encode("ascii")
                            + bytes([0x30, len(label) + 2, 0x0c, len(label)]) + label)
            extension = x509.UnrecognizedExtension(x509.ObjectIdentifier(oid), bytes([0x30, len(strings)]) + strings)
            builder = builder.add_extension(extension, critical=False)
        cert = builder.sign(key, hashes.SHA256())
        self.cert_path.write_bytes(cert.public_bytes(serialization.Encoding.PEM if pem else serialization.Encoding.DER))
        return cert

    def export(self, *options, data=b"fixture-secret\n", ok=True):
        return self.cli("export", "--type", "apns", "--certificate", self.cert_path,
                        "--confirm-topics", "--password-stdin", *options, data=data, ok=ok)

    def test_interactive_generates_both_csrs(self):
        env = {**os.environ, "HOME": self.tmp.name}
        result = subprocess.run([sys.executable, str(SCRIPT)], input=f"{BUNDLE}\n3\n".encode(),
                                env=env, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        requests = [x509.load_pem_x509_csr((self.store / ".airsim-push" / BUNDLE / kind / "request.csr").read_bytes())
                    for kind in ("apns", "voip")]
        self.assertTrue(all(request.is_signature_valid for request in requests))
        self.assertNotEqual(requests[0].public_key().public_numbers(), requests[1].public_key().public_numbers())

    def test_csr_retry_recovers_with_original_key(self):
        self.cli("csr", "--type", "apns", "--email", "me@example.org")
        private = self.key.read_bytes()
        request = self.csr.read_bytes()
        self.cli("csr", "--type", "apns", "--email", "me@example.org")
        self.assertEqual(self.csr.read_bytes(), request)
        self.csr.unlink()
        self.cli("csr", "--type", "apns", "--email", "me@example.org")
        self.assertEqual(self.key.read_bytes(), private)
        self.assertEqual(self.csr.read_bytes(), request)
        self.assertEqual(self.key.stat().st_mode & 0o077, 0)

    def test_existing_csr_without_key_is_preserved(self):
        self.create()
        request = self.csr.read_bytes()
        self.key.unlink()
        self.cli("csr", "--type", "apns", ok=False)
        self.assertEqual(self.csr.read_bytes(), request)
        self.assertFalse(self.key.exists())

    def test_rejects_mismatched_key_and_invalid_time_and_topic_uid(self):
        self.create()
        day = timedelta(days=1)
        now = datetime.now(timezone.utc)
        for case in ({"other_key": True}, {"before": now+day, "after": now+2*day},
                     {"before": now-2*day, "after": now-day}, {"uid": "com.example.other"}):
            with self.subTest(case=case):
                self.issue(**case)
                self.export(ok=False)
                self.assertFalse((self.directory / "apns.p12").exists())

    def test_export_recovers_missing_pem_preserves_existing_p12_and_accepts_pem_input(self):
        self.create()
        cert = self.issue()
        self.export()
        out = self.directory / "apns.p12"
        original = out.read_bytes()
        _, leaf, _ = pkcs12.load_key_and_certificates(original, b"fixture-secret")
        self.assertEqual(leaf, cert)
        self.assertEqual(out.stat().st_mode & 0o077, 0)
        pem = self.directory / "certificate.pem"
        pem.unlink()
        self.export()
        self.assertEqual(x509.load_pem_x509_certificate(pem.read_bytes()), leaf)
        self.export(data=b"different-password\n", ok=False)
        self.assertEqual(out.read_bytes(), original)
        new_cert = self.issue(pem=True)
        self.export(ok=False)
        new_path = self.store / "custom.p12"
        self.export("--output", new_path)
        self.assertEqual(x509.load_pem_x509_certificate(new_path.with_suffix(".pem").read_bytes()), new_cert)
        self.assertEqual(out.read_bytes(), original)

    def test_explicit_original_key_for_multitopic_certificate(self):
        self.create()
        self.issue(topics=(BUNDLE, BUNDLE + ".voip"))
        result = self.cli("export", "--type", "voip", "--certificate", self.cert_path,
                          "--key", self.key, "--password-stdin", "--confirm-topics", data=b"fixture-secret\n")
        self.assertIn(("证书声明的推送主题：" + BUNDLE + "、" + BUNDLE + ".voip").encode(), result.stdout)
        self.assertTrue((self.store / BUNDLE / "voip" / "voip.p12").is_file())

    def test_voip_requires_exact_topic_even_with_operator_confirmation(self):
        self.create()
        for topics in ((), (BUNDLE,), (BUNDLE + ".voip-ptt",), (BUNDLE + ".voip.extra",)):
            with self.subTest(topics=topics):
                self.issue(topics=topics)
                self.cli("export", "--type", "voip", "--certificate", self.cert_path, "--key", self.key,
                         "--password-stdin", "--confirm-topics", data=b"fixture-secret\n", ok=False)
                self.assertFalse((self.store / BUNDLE / "voip" / "voip.p12").exists())

    def test_dedicated_voip_extension_and_legacy_apns_cn(self):
        self.create()
        self.issue(oid="1.2.840.113635.100.6.3.4", topics=(BUNDLE + ".voip",), cn="VoIP Services: " + BUNDLE)
        self.cli("export", "--type", "voip", "--certificate", self.cert_path, "--key", self.key,
                 "--password-stdin", "--confirm-topics", data=b"fixture-secret\n")
        self.issue(cn="Apple Development IOS Push Services: " + BUNDLE)
        self.export()

    def test_refuses_empty_password_or_missing_confirmation(self):
        self.create()
        self.issue()
        self.export(data=b"\n", ok=False)
        result = self.cli("export", "--password-stdin", ok=False)
        self.assertIn(b"--confirm-topics", result.stderr)
        self.assertFalse((self.directory / "apns.p12").exists())
