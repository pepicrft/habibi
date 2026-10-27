#!/usr/bin/env python3
"""Portable unit tests and static checks of the prepared ARM64 pack."""

import copy
import gzip
import hashlib
import json
import os
from pathlib import Path
import stat
import struct
import sys
import tempfile
import unittest
from unittest.mock import patch

import network_policy
import prepare
import rpc


CODING = "--coding" in sys.argv
if CODING:
    sys.argv.remove("--coding")
    prepare.PACK = prepare.PACK.with_name("coding-pack")


def artifact():
    # A protocol fixture, not an implementation of a workout kit.
    manifest = {"apiVersion": 1, "name": "Protocol fixture", "description": "Tests only",
                "fields": [], "entrypoint": ["sh", "entry.sh"]}
    return {"revision": "a" * 40,
            "files": [{"path": "kit.json", "content": json.dumps(manifest)},
                      {"path": "entry.sh", "content": "cat\n"}]}


class ValidationTests(unittest.TestCase):
    def test_artifact_roundtrip_and_language_independence(self):
        files = rpc.validate_artifact(artifact())
        self.assertIn("kit.json", files)
        self.assertEqual(files["entry.sh"], "cat\n")

    def test_unsafe_paths(self):
        for path in ("../escape", "/absolute", "a/../b", ".git/config", "a/.GIT/x",
                     "a\\b", "a//b", "a/./b", "a\x00b", "a\nb", "C:escape", ""):
            with self.subTest(path=path), self.assertRaises(ValueError):
                rpc.safe_path(path)

    def test_limits_duplicates_and_collisions(self):
        for extra in ([{"path": "big", "content": "x" * (32768 + 1)}],
                      [{"path": str(i), "content": "x" * 32768} for i in range(4)],
                      [{"path": "a", "content": ""}, {"path": "a/b", "content": ""}],
                      [{"path": "entry.sh", "content": "duplicate"}],
                      [{"path": str(i), "content": ""} for i in range(128)]):
            value = artifact()
            value["files"].extend(extra)
            with self.subTest(extra=extra[0]["path"]), self.assertRaises(ValueError):
                rpc.validate_artifact(value)

    def test_missing_manifest_and_bad_revision(self):
        value = artifact()
        value["files"].pop(0)
        with self.assertRaises(ValueError):
            rpc.validate_artifact(value)
        value = artifact()
        value["revision"] = "b" * 64
        with self.assertRaises(ValueError):
            rpc.validate_artifact(value)

    def test_manifest_contract(self):
        manifest = json.loads(artifact()["files"][0]["content"])
        manifest["fields"] = [{"key": "count", "label": "Count", "type": "number",
                               "min": 0, "max": 100, "unit": "items"}]
        rpc.validate_manifest(json.dumps(manifest))
        manifest["fields"][0]["type"] = "integer"
        rpc.validate_manifest(json.dumps(manifest))
        for update in ({"type": "object"}, {"min": True}, {"min": 101}, {"key": "../x"}):
            invalid = copy.deepcopy(manifest)
            invalid["fields"][0].update(update)
            with self.assertRaises(ValueError):
                rpc.validate_manifest(json.dumps(invalid))

    def test_invalid_requests_echo_id_and_keep_service_alive(self):
        service = rpc.Service(Path("/unused"))
        for request in ([], {}, {"id": 123}, {"id": "not-a-uuid", "op": "exec"},
                        {"id": "11111111-1111-4111-8111-111111111111", "op": "missing"}):
            result = service.handle(request)
            self.assertFalse(result["ok"])
            self.assertIn("id", result)
            self.assertIn("error", result)

    def test_utf8_rendered_output_is_bounded(self):
        out, err, clipped = rpc.utf8_output(b"\xff" * 32768, b"error", False)
        self.assertTrue(clipped)
        self.assertLessEqual(len(out.encode()) + len(err.encode()), 32768)

    def test_regular_file_read_rejects_symlinks_and_hardlinks(self):
        prepare.BUILD.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(dir=prepare.BUILD) as directory:
            root = Path(directory)
            (root / "file").write_text("text")
            (root / "link").symlink_to("file")
            fd = os.open(str(root), os.O_RDONLY | os.O_DIRECTORY)
            try:
                self.assertEqual(rpc.read_regular(fd, "file"), "text")
                with self.assertRaises(OSError):
                    rpc.read_regular(fd, "link")
                os.link(root / "file", root / "hardlink")
                with self.assertRaises(ValueError):
                    rpc.read_regular(fd, "hardlink")
            finally:
                os.close(fd)


class CaptureTests(unittest.TestCase):
    def capture(self, source, stdin=b"", timeout=3000):
        # drop=False is solely an internal pipe-draining test, never an RPC mode.
        return rpc.capture([sys.executable, "-I", "-c", source], "/", timeout,
                           stdin, drop=False)

    def test_stdout_stderr_exit_status_and_no_loop_corruption(self):
        code, out, err, clipped = self.capture('import sys; print(\'{"event":"ready"}\'); print("err",file=sys.stderr); sys.exit(7)')
        self.assertEqual(code, 7)
        self.assertEqual(out, b'{"event":"ready"}\n')
        self.assertEqual(err, b"err\n")
        self.assertFalse(clipped)

    def test_stdin_larger_than_tty_canonical_buffer(self):
        payload = b"x" * 20000
        code, out, err, clipped = self.capture("import sys; sys.stdout.write(sys.stdin.read())", payload)
        self.assertEqual((code, out, err, clipped), (0, payload, b"", False))

    def test_combined_output_bound_and_timeout(self):
        code, out, err, clipped = self.capture('import os; os.write(1,b"x"*100000); os.write(2,b"e"*100000)')
        self.assertEqual(code, 0)
        self.assertEqual(len(out) + len(err), 32768)
        self.assertTrue(clipped)
        self.assertEqual(self.capture("import time; time.sleep(5)", timeout=100)[0], 124)

    def test_blocked_stdin_does_not_deadlock(self):
        code, _, _, _ = self.capture("import time; time.sleep(5)", b"x" * 131072, timeout=100)
        self.assertEqual(code, 124)


class NetworkPolicyTests(unittest.TestCase):
    repository = "https://github.com/octocat/Hello-World.git"

    def test_default_deny_exact_repository_and_read_only_operations(self):
        policy = network_policy.NetworkPolicy(repositories=[self.repository])
        valid = {"url": self.repository + "/info/refs?service=git-upload-pack", "method": "GET"}
        self.assertFalse(network_policy.NetworkPolicy().handle(valid)["ok"])
        self.assertEqual(policy.authorize(valid)[1], b"")
        self.assertEqual(policy.authorize({"url": self.repository + "/git-upload-pack", "method": "POST"})[1], b"")
        for url, method in ((self.repository + "/git-receive-pack", "POST"),
                            (self.repository + "/info/refs?service=git-receive-pack", "GET"),
                            (valid["url"] + "&extra=data", "GET"),
                            (valid["url"].replace("Hello-World", "Hello-World-extra"), "GET"),
                            (valid["url"].replace("github.com", "github.com.evil.invalid"), "GET"),
                            (valid["url"].replace("https:", "http:"), "GET"),
                            (valid["url"].replace("github.com", "user:secret@github.com"), "GET")):
            with self.subTest(url=url):
                self.assertFalse(policy.handle({"url": url, "method": method})["ok"])

    def test_private_and_mixed_dns_answers_are_denied_even_when_url_is_approved(self):
        url = "https://example.com/tool"
        for addresses in (["127.0.0.1"], ["169.254.169.254"], ["::1"], ["10.0.0.1"],
                          ["93.184.216.34", "192.168.1.1"]):
            with self.subTest(addresses=addresses), patch("network_policy.socket.getaddrinfo", return_value=[
                    (2, 1, 6, "", (address, 443)) for address in addresses]):
                result = network_policy.NetworkPolicy(downloads={url: "a" * 64}).handle({"url": url, "method": "GET"})
                self.assertFalse(result["ok"])
                self.assertIn("Non-public", result["error"])

    def test_request_budget_includes_denials_and_audit_is_bounded(self):
        policy = network_policy.NetworkPolicy()
        for _ in range(70):
            result = policy.handle({"url": "https://example.com/", "method": "GET"})
            self.assertFalse(result["ok"])
        self.assertEqual(policy.requests, 64)
        self.assertEqual(len(policy.audit), 64)
        self.assertIn("budget exhausted", result["error"])


def read_newc(data):
    offset, entries = 0, {}
    while True:
        if data[offset:offset + 6] != b"070701":
            raise ValueError("bad newc magic")
        fields = [int(data[offset + 6 + i * 8:offset + 14 + i * 8], 16) for i in range(13)]
        name = data[offset + 110:offset + 110 + fields[11] - 1].decode()
        offset += 110 + fields[11]
        offset += -offset % 4
        content = data[offset:offset + fields[6]]
        offset += fields[6]
        offset += -offset % 4
        if name == "TRAILER!!!":
            return entries
        entries[name] = (fields, content)


@unittest.skipUnless((prepare.PACK / "initramfs.cpio.gz").exists(), "prepare the pack first")
class PreparedPackTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.entries = read_newc(gzip.decompress((prepare.PACK / "initramfs.cpio.gz").read_bytes()))

    def resolve(self, name):
        for _ in range(20):
            fields, data = self.entries[name]
            if not stat.S_ISLNK(fields[1]):
                return fields, data
            target = data.decode()
            name = target.lstrip("/") if target.startswith("/") else str(Path(name).parent / target)
            name = os.path.normpath(name)
        self.fail("symlink loop")

    def test_manifest_checksums_and_arm64_image(self):
        manifest = json.loads((prepare.PACK / "guest-manifest.json").read_text())
        lock_path = prepare.HERE / ("coding-apk-lock.json" if CODING else "apk-lock.json")
        self.assertEqual(manifest["apkLockSha256"], hashlib.sha256(lock_path.read_bytes()).hexdigest())
        for name, value in manifest["files"].items():
            data = (prepare.PACK / name).read_bytes()
            self.assertEqual(len(data), value["bytes"])
            self.assertEqual(hashlib.sha256(data).hexdigest(), value["sha256"])
        self.assertEqual((prepare.PACK / "bzImage").read_bytes()[56:60], b"ARM\x64")

    def test_config_has_only_offline_diskless_devices(self):
        config = json.loads((prepare.PACK / "config").read_text())
        self.assertEqual((config["memory_size"], config["consoles"], config["ports"]),
                         (1024 if CODING else 512, 3 if CODING else 2, 0))
        self.assertEqual((config["kernel"], config["initrd"]), ("bzImage", "initramfs.cpio.gz"))
        self.assertFalse(any(key.startswith(("drive", "eth", "fs")) for key in config))

    def test_custom_init_module_and_empty_workspace(self):
        init = (prepare.HERE / "init").read_bytes()
        if CODING:
            self.assertEqual(self.entries["opt/habibi/coding-harness.mjs"][1],
                             (prepare.HERE / "coding-harness.mjs").read_bytes())
            self.assertEqual(self.entries["opt/habibi/network_guest.py"][1],
                             (prepare.HERE / "network_guest.py").read_bytes())
        else:
            self.assertNotIn("opt/habibi/coding-harness.mjs", self.entries)
            self.assertNotIn("opt/habibi/network_guest.py", self.entries)
        self.assertEqual(self.entries["init"][1], init)
        self.assertEqual(self.entries["opt/habibi/rpc.py"][1], (prepare.HERE / "rpc.py").read_bytes())
        module = gzip.decompress(self.entries["lib/modules/virtio_mmio.ko.gz"][1])
        self.assertIn(b"virtio_mmio", module)
        self.assertIn(b"6.12.114-0-virt", module)
        self.assertEqual(self.entries["dev/console"][0][9:11], [5, 1])
        self.assertEqual(self.entries["dev/null"][0][9:11], [1, 3])
        self.assertFalse(any(name.startswith("workspace/kit/") for name in self.entries))
        self.assertEqual(self.entries["workspace/kit"][0][2:4], [1000, 1000])
        self.assertTrue(all(not fields[1] & 0o6000 for fields, _ in self.entries.values()))

    def test_all_elf_shared_dependencies_exist(self):
        checked = 0
        for name, (fields, data) in self.entries.items():
            if not data.startswith(b"\x7fELF") or not stat.S_ISREG(fields[1]):
                continue
            self.assertEqual(data[4:6], b"\x02\x01", name)  # ELF64 little endian
            self.assertEqual(struct.unpack_from("<H", data, 18)[0], 183, name)
            phoff = struct.unpack_from("<Q", data, 32)[0]
            phsize, phcount = struct.unpack_from("<HH", data, 54)
            programs = [struct.unpack_from("<IIQQQQQQ", data, phoff + i * phsize) for i in range(phcount)]
            for program in programs:
                kind, _, offset, _, _, size, _, _ = program
                if kind == 3:  # PT_INTERP
                    self.resolve(data[offset:offset + size].rstrip(b"\0").decode().lstrip("/"))
                if kind != 2:  # PT_DYNAMIC
                    continue
                dynamic = [struct.unpack_from("<QQ", data, pos) for pos in range(offset, offset + size, 16)]
                addresses = [value for tag, value in dynamic if tag == 5]
                if not addresses:
                    continue
                address = addresses[0]
                load = next(p for p in programs if p[0] == 1 and p[3] <= address < p[3] + p[5])
                strings = load[2] + address - load[3]
                for tag, value in dynamic:
                    if tag != 1:  # DT_NEEDED
                        continue
                    end = data.index(b"\0", strings + value)
                    library = data[strings + value:end].decode()
                    candidates = [directory + "/" + library for directory in ("lib", "usr/lib")]
                    self.assertTrue(any(candidate in self.entries for candidate in candidates), (name, library))
                    self.resolve(next(candidate for candidate in candidates if candidate in self.entries))
            checked += 1
        self.assertGreater(checked, 60)
        self.assertTrue(self.resolve("usr/bin/python3")[1].startswith(b"\x7fELF"))
        self.assertTrue(self.resolve("usr/bin/git")[1].startswith(b"\x7fELF"))
        self.assertTrue(self.resolve("bin/sh")[1].startswith(b"\x7fELF"))
        self.assertTrue(self.resolve("usr/bin/env")[1].startswith(b"\x7fELF"))
        if CODING:
            self.assertTrue(self.resolve("usr/bin/node")[1].startswith(b"\x7fELF"))
            self.assertTrue(self.resolve("usr/bin/ruby")[1].startswith(b"\x7fELF"))
        else:
            self.assertNotIn("usr/bin/node", self.entries)
            self.assertNotIn("usr/bin/ruby", self.entries)


if __name__ == "__main__":
    unittest.main(verbosity=2)
