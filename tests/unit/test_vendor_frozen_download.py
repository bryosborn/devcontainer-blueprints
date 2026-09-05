"""Exercise artifact download policy through urllib's real redirect machinery."""

import email.message
import hashlib
import importlib.util
import io
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import urllib.request
import urllib.response


ROOT = Path(__file__).resolve().parents[2]
def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, ROOT / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


frozen = load("vendor_frozen_download", "src/supply/vendor/prefetch-frozen.py")
resolver = load("vendor_mutable_download", "src/supply/vendor/resolve-vendor.py")
apk = load("apk_supply_download", "src/supply/apk/supply_lib.py")


class DownloadPolicyTests:
    error_type = SystemExit
    failure_message = "failed to download"
    hash_message = "SHA256 mismatch"

    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.destination = self.root / "payload"
        self.payload = b"verified frozen artifact"
        self.digest = hashlib.sha256(self.payload).hexdigest()
        self.requests = []
        self.responder = lambda url: (200, {}, self.payload)
        test = self

        class FixtureTransport(urllib.request.BaseHandler):
            # Run before urllib's network transports, preserving its actual
            # redirect/error processing without opening any network sockets.
            handler_order = 100

            def https_open(self, request):
                test.requests.append(request.full_url)
                status, fields, body = test.responder(request.full_url)
                headers = email.message.Message()
                for key, value in fields.items():
                    headers[key] = value
                response = urllib.response.addinfourl(
                    io.BytesIO(body), headers, request.full_url, status,
                )
                response.msg = "fixture response"
                return response

            http_open = https_open

        build_opener = urllib.request.build_opener
        opener_patch = patch.object(
            self.module.urllib.request,
            "build_opener",
            side_effect=lambda *handlers: build_opener(*handlers, FixtureTransport()),
        )
        opener_patch.start()
        self.addCleanup(opener_patch.stop)
        # Cover callers using either urlopen or a dedicated opener; both use
        # the real urllib redirect processing and the same offline transport.
        default_opener = patch.object(
            self.module.urllib.request, "_opener", build_opener(FixtureTransport()),
        )
        default_opener.start()
        self.addCleanup(default_opener.stop)
        sleep_patch = patch.object(self.module.time, "sleep")
        self.sleep = sleep_patch.start()
        self.addCleanup(sleep_patch.stop)

    def test_rejects_intermediate_http_hop_before_request_or_retry(self):
        redirects = {
            "https://origin.invalid/payload": "http://middle.invalid/payload",
            "http://middle.invalid/payload": "https://final.invalid/payload",
        }
        self.responder = lambda url: (
            (302, {"Location": redirects[url]}, b"")
            if url in redirects else (200, {}, self.payload)
        )
        with self.assertRaisesRegex(self.error_type, "non-HTTPS"):
            self.fetch("https://origin.invalid/payload", self.destination, self.digest)
        self.assertEqual(self.requests, ["https://origin.invalid/payload"])
        self.sleep.assert_not_called()
        self.assertEqual(list(self.root.iterdir()), [])

    def test_allows_https_redirects_and_promotes_only_verified_bytes(self):
        self.responder = lambda url: (
            (302, {"Location": "https://final.invalid/payload"}, b"")
            if "origin.invalid" in url else (200, {}, self.payload)
        )
        self.fetch("https://origin.invalid/payload", self.destination, self.digest)
        self.assertEqual(self.requests, [
            "https://origin.invalid/payload", "https://final.invalid/payload",
        ])
        self.assertEqual(self.destination.read_bytes(), self.payload)
        self.assertEqual(list(self.root.iterdir()), [self.destination])
        self.sleep.assert_not_called()

    def test_transient_failures_stop_after_five_attempts(self):
        self.responder = lambda url: (503, {}, b"temporarily unavailable")
        with self.assertRaisesRegex(self.error_type, self.failure_message):
            self.fetch("https://origin.invalid/payload", self.destination, self.digest)
        self.assertEqual(len(self.requests), 5)
        self.assertEqual([call.args[0] for call in self.sleep.call_args_list], [1, 2, 4, 8])
        self.assertEqual(list(self.root.iterdir()), [])

    def test_permanent_http_error_is_not_retried(self):
        self.responder = lambda url: (404, {}, b"not found")
        with self.assertRaisesRegex(self.error_type, "download rejected"):
            self.fetch("https://origin.invalid/payload", self.destination, self.digest)
        self.assertEqual(len(self.requests), 1)
        self.sleep.assert_not_called()
        self.assertEqual(list(self.root.iterdir()), [])

    def test_hash_mismatch_is_fatal_and_preserves_existing_destination(self):
        self.destination.write_bytes(b"existing artifact")
        self.responder = lambda url: (200, {}, b"unexpected bytes")
        with self.assertRaisesRegex(self.error_type, self.hash_message):
            self.fetch("https://origin.invalid/payload", self.destination, self.digest)
        self.assertEqual(len(self.requests), 1)
        self.assertEqual(self.destination.read_bytes(), b"existing artifact")
        self.assertEqual(list(self.root.iterdir()), [self.destination])
        self.sleep.assert_not_called()


class FrozenDownloadTests(DownloadPolicyTests, unittest.TestCase):
    module = frozen
    fetch = staticmethod(frozen.fetch)


class ResolverDownloadTests(DownloadPolicyTests, unittest.TestCase):
    module = resolver
    fetch = staticmethod(resolver.download_locked)

    def test_attempt_override_cannot_exceed_five_or_disable_downloads(self):
        for attempts in (0, 6, True):
            with self.subTest(attempts=attempts), self.assertRaisesRegex(SystemExit, "1 through 5"):
                resolver.fetch_bytes("https://origin.invalid/payload", attempts=attempts)
        self.assertEqual(self.requests, [])


class ApkDownloadTests(DownloadPolicyTests, unittest.TestCase):
    module = apk
    error_type = apk.SupplyError
    failure_message = "unable to download"
    hash_message = "checksum mismatch"

    @staticmethod
    def fetch(url, destination, digest):
        return apk.download(url, destination, expected_sha256=digest)


if __name__ == "__main__":
    unittest.main()
