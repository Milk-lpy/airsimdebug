"""Offline tests for the provisioning workflow."""
import base64
import copy
import io
import os
import plistlib
import subprocess
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from datetime import datetime, timedelta, timezone
from pathlib import Path
from unittest.mock import Mock, patch

import setup


BUNDLE = "com.example.airsim"
TEAM = "A123456789"
PREFIX = "B123456789"
GROUPS = ["group.com.example.airsim"]


class SetupTests(unittest.TestCase):
    def setUp(self):
        for stream in [redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO())]:
            stream.__enter__()
            self.addCleanup(stream.__exit__, None, None, None)

    def test_preview_is_offline_and_returns_zero(self):
        with patch.object(setup, "AppleAPI", side_effect=AssertionError):
            self.assertEqual(0, setup.main(["--bundle", BUNDLE]))

    def test_partial_and_conflicting_flags_fail_before_api(self):
        for argv in [
            ["--apply", "--bundle", BUNDLE, "--certificate", "c"],
            ["--apply", "--bundle", BUNDLE, "--output", "my.mobileprovision"],
            ["--verify", "f", "--apply"],
        ]:
            with self.subTest(argv=argv), self.assertRaises(SystemExit) as ctx:
                setup.main(argv)
            self.assertEqual(ctx.exception.code, 2)

    def test_existing_output_precedes_account_write(self):
        with tempfile.TemporaryDirectory() as folder:
            output = Path(folder) / "existing"
            output.write_bytes(b"previous")
            with patch.object(setup, "AppleAPI", side_effect=AssertionError), self.assertRaises(setup.WorkflowError):
                setup.main(["--apply", "--bundle", BUNDLE, "--certificate", "c", "--device", "d", "--output", str(output)])
            self.assertEqual(output.read_bytes(), b"previous")

    def test_enable_only_missing_and_retry_after_partial_failure(self):
        existing = set(setup.CAPS[:-2])
        api = Mock()
        def resources(path, **kwargs):
            if path == "bundleIds":
                return [{"id": "bid"}]
            return [{"attributes": {"capabilityType": x}} for x in existing]
        api.list.side_effect = resources
        def create(resource, attributes, relationships):
            self.assertEqual(resource, "bundleIdCapabilities")
            self.assertEqual(relationships["bundleId"]["data"]["id"], "bid")
            cap = attributes["capabilityType"]
            if cap == setup.CAPS[-1]:
                raise setup.AppleError(409, "manual")
            existing.add(cap)
        api.create.side_effect = create
        with self.assertRaises(setup.WorkflowError):
            setup.configure(api, BUNDLE)
        existing.add(setup.CAPS[-1])
        api.create.reset_mock()
        self.assertEqual("bid", setup.configure(api, BUNDLE))
        api.create.assert_not_called()

    def test_profile_relationships_and_exclusive_export(self):
        api = Mock(issuer="issuer")
        payload = b"fixture bytes"
        api.create.return_value = {"id": "123", "attributes": {"profileContent": base64.b64encode(payload).decode()}}
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "out"
            args = setup.arguments(["--bundle", BUNDLE, "--certificate", "c", "--device", "d", "--device", "d"])
            with tempfile.NamedTemporaryFile(dir=directory) as stage:
                setup.save_profile(api, args, "bundle-id", output, stage)
            self.assertEqual(output.read_bytes(), payload)
            self.assertEqual(output.stat().st_mode & 0o777, 0o600)
            resource, attrs, rel = api.create.call_args.args
            self.assertEqual(resource, "profiles")
            self.assertEqual(attrs["profileType"], "IOS_APP_DEVELOPMENT")
            self.assertEqual(rel["devices"]["data"], [{"type": "devices", "id": "d"}])
            self.assertEqual(rel["certificates"]["data"][0]["id"], "c")
            self.assertEqual(rel["bundleId"]["data"]["id"], "bundle-id")

    def test_expected_entitlements_expiry_and_identity(self):
        now = datetime.now(timezone.utc)
        profile = {
            "Entitlements": setup.expected_entitlements(BUNDLE, TEAM, PREFIX, GROUPS),
            "ApplicationIdentifierPrefix": [PREFIX], "TeamIdentifier": [TEAM],
            "ExpirationDate": (now + timedelta(days=1)).replace(tzinfo=None),
        }
        self.assertEqual(24, len(profile["Entitlements"]))
        self.assertEqual(0, setup.check_profile(profile, BUNDLE, TEAM, PREFIX, GROUPS, now))
        for key, value in [("TeamIdentifier", ["A999999999"]), ("ExpirationDate", now), ("ExpirationDate", "2025")]:
            self.assertEqual(1, setup.check_profile({**profile, key: value}, BUNDLE, TEAM, PREFIX, GROUPS, now))
        self.assertEqual(1, setup.check_profile(profile, "com.example.other", TEAM, PREFIX, GROUPS, now))
        self.assertEqual(1, setup.check_profile(profile, BUNDLE, TEAM, TEAM, GROUPS, now))
        mismatch = copy.deepcopy(profile)
        mismatch["Entitlements"]["get-task-allow"] = 1
        self.assertEqual(1, setup.check_profile(mismatch, BUNDLE, TEAM, PREFIX, GROUPS, now))

    def test_read_signed_cms_and_reject_invalid_data(self):
        with tempfile.TemporaryDirectory() as directory:
            def run(*cmd):
                subprocess.run(["openssl", *cmd], cwd=directory, check=True, capture_output=True)
            profile = {
                "Entitlements": setup.expected_entitlements(BUNDLE, TEAM, PREFIX, GROUPS),
                "TeamIdentifier": [TEAM], "ApplicationIdentifierPrefix": [PREFIX],
                "ExpirationDate": (datetime.now(timezone.utc) + timedelta(days=1)).replace(tzinfo=None),
            }
            root = Path(directory)
            (root / "input").write_bytes(plistlib.dumps(profile))
            run("req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", "key", "-out", "ca",
                "-subj", "/CN=Offline Fixture", "-days", "1")
            run("cms", "-sign", "-nodetach", "-binary", "-in", "input", "-outform", "DER", "-out", "profile",
                "-signer", "ca", "-inkey", "key")
            profile["ExpirationDate"] = profile["ExpirationDate"].replace(microsecond=0)
            args = ["--verify", str(root / "profile"), "--ca-file", str(root / "ca"),
                    "--bundle", BUNDLE, "--team-id", TEAM, "--app-id-prefix", PREFIX,
                    "--app-group", GROUPS[0]]
            self.assertEqual(0, setup.main(args))
            self.assertEqual(1, setup.main(args + ["--bundle", "com.example.wrong"]))
            self.assertEqual(profile, setup.read_profile(root / "profile", root / "ca"))
            self.assertEqual(profile, setup.read_profile(root / "profile", None))
            with self.assertRaises(setup.WorkflowError):
                setup.read_profile(root / "input", None)

    def test_apply_single_capability(self):
        api = Mock(issuer="fixture")
        api.list.side_effect = [[{"id": "bundle"}], []]
        with patch.object(setup, "AppleAPI", return_value=api), patch("builtins.input", return_value="YES"):
            self.assertEqual(0, setup.main(["--apply", "--bundle", BUNDLE, "--capability", "APP_GROUPS"]))
        api.create.assert_called_once_with("bundleIdCapabilities", {"capabilityType": "APP_GROUPS"},
                                           {"bundleId": {"data": {"type": "bundleIds", "id": "bundle"}}})

    def test_list_follows_apple_paging(self):
        api = object.__new__(setup.AppleAPI)
        url = setup.API_ROOT + "devices?cursor=2"
        api.request = Mock(side_effect=[{"data": [1], "links": {"next": url}}, {"data": [2]}])
        self.assertEqual([1, 2], list(api.list("devices", **{"filter[status]": "ENABLED"})))
        self.assertEqual(api.request.call_args.args, ("GET", url))
        self.assertIsNone(api.request.call_args.kwargs["params"])

    def test_missing_credentials_report_names(self):
        with patch.dict(os.environ, {}, clear=True), self.assertRaisesRegex(setup.WorkflowError, "ASC_ISSUER_ID"):
            setup.AppleAPI()

    def test_api_request_uses_short_lived_signed_team_token(self):
        import jwt
        from cryptography.hazmat.primitives import serialization
        from cryptography.hazmat.primitives.asymmetric import ec

        private_key = ec.generate_private_key(ec.SECP256R1())
        with tempfile.TemporaryDirectory() as folder:
            key_path = Path(folder) / "AuthKey.p8"
            key_path.write_bytes(private_key.private_bytes(
                serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()))
            credentials = {"ASC_KEY_PATH": str(key_path), "ASC_KEY_ID": "test-key", "ASC_ISSUER_ID": "test-team"}
            with patch.dict(os.environ, credentials):
                api = setup.AppleAPI()
        response = Mock(status_code=200)
        response.json.return_value = {"data": []}
        with patch.object(api.requests, "request", return_value=response) as send:
            self.assertEqual(list(api.list("devices")), [])
        self.assertEqual(send.call_args.args, ("GET", setup.API_ROOT + "devices"))
        self.assertFalse(send.call_args.kwargs["allow_redirects"])
        auth = send.call_args.kwargs["headers"]["Authorization"]
        self.assertTrue(auth.startswith("Bearer "))
        token = auth.removeprefix("Bearer ")
        self.assertEqual(jwt.get_unverified_header(token)["kid"], "test-key")
        claims = jwt.decode(token, private_key.public_key(), algorithms=["ES256"],
                            audience="appstoreconnect-v1", issuer="test-team")
        self.assertLessEqual(claims["exp"] - claims["iat"], 20 * 60)


if __name__ == "__main__":
    unittest.main()
