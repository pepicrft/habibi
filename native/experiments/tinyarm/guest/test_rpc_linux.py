#!/usr/bin/env python3
"""Public-JSONL integration tests. ONLY run in a dedicated disposable Linux VM.

HABIBI_DISPOSABLE_RPC_TEST=1 python3 -B test_rpc_linux.py
Requires root, Python3, /usr/bin/git and /bin/sh. Kills all uid1000 processes.
"""

import json
import os
from pathlib import Path
import select
import shutil
import subprocess
import sys
import tempfile
import unittest
import uuid


HERE = Path(__file__).resolve().parent
BUILD = HERE.parents[3] / ".amp/in/tinyarm-sim/guest-build"
ENABLED = sys.platform == "linux" and os.geteuid() == 0 and os.environ.get("HABIBI_DISPOSABLE_RPC_TEST") == "1"


@unittest.skipUnless(ENABLED, "requires explicit disposable Linux root opt-in")
class RpcTests(unittest.TestCase):
    def setUp(self):
        BUILD.mkdir(parents=True, exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(dir=BUILD)
        self.root = Path(self.temp.name)
        self.root.chmod(0o755)
        self.workspace = self.root / "workspace"
        self.workspace.mkdir()
        for name in ("kit", "home"):
            directory = self.workspace / name
            directory.mkdir()
            os.chown(directory, 1000, 1000)
        shutil.copyfile(HERE / "rpc.py", self.root / "rpc.py")
        self.process = subprocess.Popen([sys.executable, "-I", "-B", str(self.root / "rpc.py"),
                                         "--workspace", str(self.workspace)],
                                        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                        env={**os.environ, "HABIBI_ENV_SENTINEL": "must-not-inherit"})
        self.buffer = b""
        ready = self.receive()
        self.assertEqual((ready["event"], ready["protocol"]), ("ready", 1))
        self.assertIn("git version", ready["git"])

    def tearDown(self):
        self.process.stdin.close()
        try:
            self.process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait()
        self.process.stdout.close()
        self.process.stderr.close()
        self.temp.cleanup()

    def receive(self):
        while b"\n" not in self.buffer:
            self.assertTrue(select.select([self.process.stdout], [], [], 30)[0], "RPC host deadline exceeded")
            chunk = os.read(self.process.stdout.fileno(), 65536)
            if not chunk:
                self.fail("server exited: " + self.process.stderr.read().decode())
            self.buffer += chunk
        line, self.buffer = self.buffer.split(b"\n", 1)
        return json.loads(line)

    def call(self, op, **kwargs):
        request_id = str(uuid.uuid4())
        self.process.stdin.write(json.dumps({"id": request_id, "op": op, **kwargs}).encode() + b"\n")
        self.process.stdin.flush()
        response = self.receive()
        self.assertEqual(response["id"], request_id)
        self.assertIsInstance(response["ok"], bool)
        return response

    def execute(self, argv, stdin="", timeout=10000):
        result = self.call("exec", argv=argv, stdin=stdin, timeoutMs=timeout)
        self.assertTrue(result["ok"], result)
        return result

    def seed_repository(self):
        manifest = {"apiVersion": 1, "name": "Test", "description": "Protocol fixture only",
                    "fields": [], "entrypoint": ["sh", "entry.sh"]}
        script = ("import pathlib,subprocess; p=pathlib.Path('.'); "
                  "(p/'kit.json').write_text(%r); (p/'entry.sh').write_text('cat\\n'); "
                  "subprocess.run(['git','init'],check=True); "
                  "subprocess.run(['git','add','.'],check=True); "
                  "subprocess.run(['git','-c','user.name=Test','-c','user.email=test@invalid',"
                  "'-c','commit.gpgsign=false','commit','-m','fixture'],check=True)" % json.dumps(manifest))
        self.assertEqual(self.execute([sys.executable, "-c", script])["exitCode"], 0)

    def test_exec_identity_environment_limits_stdin_and_output(self):
        source = ("import json,os,resource; print(json.dumps({'uid':os.getuid(),'gid':os.getgid(),"
                  "'groups':os.getgroups(),'cwd':os.getcwd(),'env':dict(os.environ),"
                  "'limits':[resource.getrlimit(x) for x in [resource.RLIMIT_CPU,resource.RLIMIT_AS,"
                  "resource.RLIMIT_FSIZE,resource.RLIMIT_NOFILE]]}))")
        result = self.execute([sys.executable, "-c", source])
        info = json.loads(result["stdout"])
        self.assertEqual((info["uid"], info["gid"], info["groups"]), (1000, 1000, []))
        self.assertEqual(info["cwd"], str(self.workspace / "kit"))
        self.assertEqual(info["env"]["PATH"], "/usr/bin:/bin")
        self.assertNotIn("HABIBI_ENV_SENTINEL", info["env"])
        self.assertEqual(info["limits"][1:], [[201326592, 201326592], [8388608, 8388608], [64, 64]])
        result = self.execute(["/bin/sh", "-c", "cat; printf err >&2; exit 7"], "x" * 20000)
        self.assertEqual((result["stdout"], result["stderr"], result["exitCode"]), ("x" * 20000, "err", 7))
        result = self.execute([sys.executable, "-c", "import os; os.write(1,b'x'*65536); os.write(2,b'y'*65536)"])
        self.assertTrue(result["truncated"])
        self.assertEqual(len(result["stdout"].encode()) + len(result["stderr"].encode()), 32768)
        self.assertEqual(self.execute(["/bin/sh", "-c", "sleep 5"], timeout=100)["exitCode"], 124)
        self.assertEqual(self.execute(["/bin/sh", "-c", "printf intact"])["stdout"], "intact")

    def test_detached_child_is_cleaned_up(self):
        source = ("import os,time; pid=os.fork(); "
                  "print(pid,flush=True) if pid else None; "
                  "os._exit(0) if pid else None; os.setsid(); "
                  "os.close(0); os.close(1); os.close(2); time.sleep(15)")
        result = self.execute([sys.executable, "-c", source])
        child = int(result["stdout"].strip())
        self.assertFalse(Path("/proc/%d" % child).exists())

    def test_export_real_git_clean_only_and_import_not_after_exec(self):
        self.seed_repository()
        result = self.call("export")
        self.assertTrue(result["ok"], result)
        self.assertEqual(len(result["artifact"]["revision"]), 40)
        self.assertEqual({f["path"] for f in result["artifact"]["files"]}, {"kit.json", "entry.sh"})
        self.assertFalse(self.call("import", artifact=result["artifact"])["ok"])
        self.execute(["/bin/sh", "-c", "printf dirty >> entry.sh"])
        self.assertFalse(self.call("export")["ok"])

    def test_export_rejects_tracked_symlink(self):
        self.seed_repository()
        self.execute(["/bin/sh", "-c", "ln -s /etc/passwd link; git add link; git -c user.name=Test -c user.email=test@invalid -c commit.gpgsign=false commit -m symlink"])
        self.assertFalse(self.call("export")["ok"])

    def test_import_fresh_workspace_and_errors_leave_rpc_alive(self):
        manifest = {"apiVersion": 1, "name": "Test", "description": "Only a fixture",
                    "fields": [], "entrypoint": ["sh", "entry.sh"]}
        artifact = {"revision": "a" * 40, "files": [{"path": "kit.json", "content": json.dumps(manifest)},
                                                     {"path": "entry.sh", "content": "cat\n"}]}
        unsafe = {"revision": "a" * 40, "files": [{"path": "../escape", "content": "x"}]}
        self.assertFalse(self.call("import", artifact=unsafe)["ok"])
        self.assertTrue(self.call("import", artifact=artifact)["ok"])
        self.assertFalse((self.workspace / "kit/.git").exists())
        self.assertEqual(self.execute(["/bin/sh", "entry.sh"], "private stdin")["stdout"], "private stdin")
        self.assertFalse(self.call("import", artifact=artifact)["ok"])
        self.assertFalse(self.call("exec", argv=["sh"], timeoutMs=20001)["ok"])
        self.process.stdin.write(b'{"id":NaN}\nnot-json\n' + b" " * (1024 * 1024 + 1) + b"\n")
        self.process.stdin.flush()
        for _ in range(3):
            self.assertFalse(self.receive()["ok"])
        self.assertEqual(self.execute(["/bin/sh", "-c", "printf alive"])["stdout"], "alive")


if __name__ == "__main__":
    if ENABLED:
        # Refuse to run on a normal Linux desktop even if the flag was copied.
        for entry in Path("/proc").iterdir():
            if entry.name.isdigit():
                try:
                    status = (entry / "status").read_text()
                    uid = next(line for line in status.splitlines() if line.startswith("Uid:"))
                    if "1000" in uid.split()[1:]:
                        sys.exit("Refusing: pre-existing uid1000 process. Use a dedicated disposable VM.")
                except OSError:
                    pass
    unittest.main(verbosity=2)
