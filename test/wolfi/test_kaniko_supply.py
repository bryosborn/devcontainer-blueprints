"""Frozen signed-graph, extraction and wrapper behavior for optional Kaniko."""
import copy
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import struct
import subprocess
import tarfile
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("kaniko_supply", ROOT / "src/wolfi/vendor-artifacts/scripts/kaniko_supply.py")
supply = importlib.util.module_from_spec(spec)
spec.loader.exec_module(supply)


def elf(machine=62, interpreter=False):
    value = bytearray(128)
    value[:6] = b"\x7fELF\x02\x01"
    struct.pack_into("<H", value, 18, machine)
    struct.pack_into("<Q", value, 32, 64)
    struct.pack_into("<HH", value, 54, 56, 1)
    struct.pack_into("<I", value, 64, 3 if interpreter else 1)
    return bytes(value)


class KanikoSupplyTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def layer(self, files, name="layer.tar", symlink=None):
        path = self.root / name
        with tarfile.open(path, "w") as archive:
            for key, value in files.items():
                member = tarfile.TarInfo(key)
                member.size = len(value)
                if key == symlink:
                    member.type, member.linkname, member.size = tarfile.SYMTYPE, "/etc/passwd", 0
                    archive.addfile(member)
                else:
                    archive.addfile(member, io.BytesIO(value))
        return path

    def payload(self):
        return {"kaniko/executor": elf(), "kaniko/tini": elf(),
                "kaniko/ssl/certs/ca-certificates.crt": b"-----BEGIN CERTIFICATE-----\nfixture\n"}

    def graph(self):
        layer = self.layer(self.payload())
        sources = []
        def descriptor(kind, value):
            data = value if isinstance(value, bytes) else json.dumps(value).encode()
            digest = "sha256:" + hashlib.sha256(data).hexdigest()
            path = self.root / digest[7:]
            path.write_bytes(data)
            item = supply.file_record(path, self.root, kind=kind, digest=digest,
                                     url=f"{supply.REGISTRY}/{'manifests' if kind in ('index','manifest') else 'blobs'}/{digest}")
            sources.append(item)
            return {"digest": digest, "size": len(data)}
        config = descriptor("config", {"os":"linux", "architecture":"amd64"})
        layer_record = descriptor("layer", layer.read_bytes())
        manifest = descriptor("manifest", {"config":config, "layers":[layer_record]})
        index = descriptor("index", {"manifests":[{**manifest, "platform":{"os":"linux","architecture":"amd64"}}]})
        identity = "https://github.com/osscontainertools/kaniko/.github/workflows/images.yaml@refs/tags/v1.28.4"
        evidence = self.root / "evidence.json"
        evidence.write_text(json.dumps({"image":f"{supply.REPOSITORY}@{index['digest']}", "identity":identity,
                                        "issuer":supply.ISSUER, "cosign":{"gitVersion":"v3.1.3"}, "signatures":[{"critical":{"image":{"docker-manifest-digest":index["digest"]}}}]}))
        archive = self.root / "kaniko.tar.gz"
        supply.write_payload(archive, self.payload())
        return {"version":"1.28.4", "platform":"linux/amd64", "image":f"{supply.REPOSITORY}:v1.28.4", "indexDigest":index["digest"],
                "manifestDigest":manifest["digest"], "configDigest":config["digest"], "sources":sources,
                "signature":supply.file_record(evidence,self.root,identity=identity,issuer=supply.ISSUER,cosignVersion="v3.1.3"),
                "archive":supply.file_record(archive,self.root),
                "payloads":[{"path":key.removeprefix("kaniko/"), "sha256":hashlib.sha256(value).hexdigest(), "size":len(value)}
                            for key,value in sorted(self.payload().items())]}

    def test_extracts_only_selected_regular_files(self):
        layer = self.layer({**self.payload(),"kaniko/docker-credential-extra":b"excluded","etc/os-release":b"excluded"})
        self.assertEqual(supply.extract_payload([layer],"linux/amd64"),self.payload())

    def test_whiteout_removes_selected_payload(self):
        layers = [self.layer(self.payload()), self.layer({"kaniko/.wh.executor":b""},"second.tar")]
        with self.assertRaisesRegex(SystemExit,"lacks executor"):
            supply.extract_payload(layers,"linux/amd64")

    def test_whiteout_does_not_remove_same_layer_replacement(self):
        layers = [self.layer(self.payload()), self.layer({"kaniko/executor": elf(), "kaniko/.wh.executor": b""}, "replacement.tar")]
        self.assertEqual(supply.extract_payload(layers, "linux/amd64"), self.payload())

    def test_rejects_links_traversal_foreign_architecture_and_dynamic_elf(self):
        with self.assertRaisesRegex(SystemExit,"regular file"):
            supply.extract_payload([self.layer(self.payload(),symlink="kaniko/executor")],"linux/amd64")
        with self.assertRaisesRegex(SystemExit,"unsafe source"):
            supply.extract_payload([self.layer({**self.payload(),"../../outside":b"x"})],"linux/amd64")
        for value in (elf(183),elf(interpreter=True)):
            with self.assertRaises(SystemExit):
                supply.extract_payload([self.layer({**self.payload(),"kaniko/executor":value})],"linux/amd64")

    def test_archive_is_reproducible_and_has_no_foreign_files(self):
        first,second=self.root/'first.tar.gz',self.root/'second.tar.gz'
        supply.write_payload(first,self.payload())
        supply.write_payload(second,dict(reversed(list(self.payload().items()))))
        self.assertEqual(first.read_bytes(),second.read_bytes())
        with tarfile.open(first) as archive:
            self.assertEqual(archive.getnames(),["executor","ssl/certs/ca-certificates.crt","tini"])
            self.assertTrue(all(m.isreg() and m.uid==0 and m.mtime==0 for m in archive))

    def test_frozen_graph_can_rebuild_payload_without_network(self):
        record=self.graph()
        (self.root/record['archive']['file']).unlink()
        with patch.object(supply.Registry,'fetch',side_effect=AssertionError('network forbidden')):
            supply.prefetch_kaniko(record,self.root,offline=True)
        supply.verified(record['archive'],self.root)

    def test_frozen_graph_rejects_tampered_artifacts_and_evidence(self):
        record=self.graph()
        for section in ('signature','archive'):
            target = self.root / record[section]['file']
            original = target.read_bytes()
            target.write_bytes(b'tampered')
            with self.assertRaisesRegex(SystemExit,'modified frozen artifact'):
                supply.prefetch_kaniko(record,self.root,offline=True)
            target.write_bytes(original)

    def test_frozen_graph_rejects_wrong_identity_platform_and_payload(self):
        record=self.graph()
        for change in ('identity','platform','payload'):
            wrong=copy.deepcopy(record)
            if change == 'identity':
                wrong['signature']['identity'] = 'https://example.test/untrusted'
            elif change == 'platform':
                wrong['platform'] = 'linux/arm64'
            else:
                wrong['payloads'][0]['sha256'] = '0' * 64
            with self.assertRaises(SystemExit):
                supply.prefetch_kaniko(wrong, self.root, offline=True)

    def test_download_hash_failure_does_not_retry(self):
        response=unittest.mock.MagicMock()
        response.__enter__.return_value=response
        response.geturl.return_value='https://example.test/artifact'
        response.read.return_value=b'changed'
        with patch.object(supply.urllib.request.OpenerDirector,'open',return_value=response) as request:
            with self.assertRaisesRegex(SystemExit,'SHA256 mismatch'):
                supply.Registry().fetch('https://example.test/artifact','0'*64)
            self.assertEqual(request.call_count,1)

    def test_download_refuses_http_redirect(self):
        response=unittest.mock.MagicMock()
        response.__enter__.return_value=response
        response.geturl.return_value='http://example.test/artifact'
        with patch.object(supply.urllib.request.OpenerDirector,'open',return_value=response):
            with self.assertRaisesRegex(SystemExit,'non-HTTPS redirect'):
                supply.Registry().fetch('https://example.test/artifact')

    def test_redirect_strips_registry_authorization(self):
        request = supply.urllib.request.Request(supply.REGISTRY + "/blobs/sha256:abc", headers={"Authorization": "Bearer public-token"})
        redirected = supply.HTTPSRedirect().redirect_request(request, None, 302, "redirect", {}, "https://blob.example.test/layer")
        self.assertFalse(redirected.has_header("Authorization"))
        with self.assertRaisesRegex(SystemExit, "non-HTTPS redirect"):
            supply.HTTPSRedirect().redirect_request(request, None, 302, "redirect", {}, "http://blob.example.test/layer")

    def test_transient_download_retries_are_bounded(self):
        with patch.object(supply.urllib.request.OpenerDirector, "open", side_effect=OSError("transient")) as request, patch.object(supply.time, "sleep"):
            with self.assertRaisesRegex(SystemExit, "five attempts"):
                supply.Registry().fetch("https://example.test/artifact")
            self.assertEqual(request.call_count, 5)

    def test_wrapper_requires_root_and_rejects_filesystem_mode_overrides(self):
        wrapper=ROOT/'src/wolfi/components/kaniko/kaniko-build'
        fake = self.root / 'id'
        fake.write_text('#!/bin/sh\necho 1001\n')
        fake.chmod(0o755)
        env={**os.environ,'PATH':f'{self.root}:{os.environ["PATH"]}'}
        result=subprocess.run(['bash',str(wrapper)],env=env,capture_output=True,text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('requires UID 0', result.stderr)
        fake.write_text('#!/bin/sh\necho 0\n')
        for option in ('--cleanup=false','--pre-cleanup=true','--preserve-context=false','--kaniko-dir=/tmp','--force'):
            result=subprocess.run(['bash',str(wrapper),option],env=env,capture_output=True,text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('controls its filesystem', result.stderr)

    def test_wrapper_rejects_context_subpath_instead_of_building_parent_context(self):
        wrapper = ROOT / 'src/wolfi/components/kaniko/kaniko-build'
        fake = self.root / 'id'
        fake.write_text('#!/bin/sh\necho 0\n')
        fake.chmod(0o755)
        env = {**os.environ, 'PATH': f'{self.root}:{os.environ["PATH"]}'}
        for options in (['--context-sub-path', 'app'], ['--context-sub-path=app']):
            with self.subTest(options=options):
                result = subprocess.run(
                    ['bash', str(wrapper), '--context', f'dir://{self.root}', *options],
                    env=env, capture_output=True, text=True,
                )
                self.assertEqual(result.returncode, 2)
                self.assertIn('ignores --context-sub-path for local contexts', result.stderr)
                self.assertIn('Select the desired directory directly with --context DIRECTORY', result.stderr)


if __name__ == '__main__':
    unittest.main()
