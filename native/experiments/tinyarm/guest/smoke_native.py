#!/usr/bin/env python3
"""Boot the real guest via the parent-built iOS simulator static TinyARM library."""

import argparse
import json
import os
from pathlib import Path
import select
import subprocess
import time
import uuid

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[3]
BUILD = ROOT / ".amp/in/tinyarm-sim/guest-build"
PACK = ROOT / ".amp/in/tinyarm-sim/pack"


class Vm:
    def __init__(self, command, label, network=None, boot_timeout=120):
        self.network = network
        self.log = (BUILD / (label + ".log")).open("wb")
        self.process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=self.log)
        self.pending = b""
        try:
            self.ready = self.receive(boot_timeout)
        except Exception:
            self.close()
            raise
        assert self.ready["event"] == "ready" and self.ready["protocol"] == 1, self.ready
        print(label, self.ready, flush=True)

    def receive(self, timeout=60):
        deadline = time.monotonic() + timeout
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise RuntimeError("native RPC deadline; inspect guest-build/*.log")
            if b"\n" not in self.pending:
                if not select.select([self.process.stdout], [], [], remaining)[0]:
                    raise RuntimeError("native RPC deadline; inspect guest-build/*.log")
                data = os.read(self.process.stdout.fileno(), 65536)
                if not data:
                    raise RuntimeError("native host exited; inspect guest-build/*.log")
                self.pending += data
                if len(self.pending) > 1024 * 1024:
                    raise RuntimeError("Guest exceeded host transport output budget")
                continue
            line, self.pending = self.pending.split(b"\n", 1)
            value = json.loads(line)
            if value.get("event") != "network":
                return value
            result = self.network.handle(value) if self.network else {"ok": False, "error": "Network disabled"}
            self.process.stdin.write(b"@" + json.dumps(result).encode() + b"\n")
            self.process.stdin.flush()

    def call(self, op, receive_timeout=60, **kwargs):
        request_id = str(uuid.uuid4())
        self.process.stdin.write(json.dumps({"id": request_id, "op": op, **kwargs}).encode() + b"\n")
        self.process.stdin.flush()
        response = self.receive(receive_timeout)
        assert response["id"] == request_id, response
        assert isinstance(response["ok"], bool), response
        return response

    def execute(self, argv, stdin="", timeout=20000):
        response = self.call("exec", argv=argv, stdin=stdin, timeoutMs=timeout,
                             receive_timeout=max(60, timeout / 1000 + 15))
        assert response["ok"], response
        return response

    def close(self):
        self.process.stdin.close()
        try:
            self.process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait()
        self.process.stdout.close()
        self.log.close()


def check_user_namespaces(vm):
    result = vm.execute(["python3", "-c",
        "import ctypes,json,os; lib=ctypes.CDLL(None,use_errno=True); "
        "before=os.getuid(); attempt=lib.unshare(0x10000000); "
        "print(json.dumps({'uid':before,'result':attempt,'errno':ctypes.get_errno(),"
        "'limit':int(open('/proc/sys/user/max_user_namespaces').read())}))"])
    assert result["exitCode"] == 0, result
    probe = json.loads(result["stdout"])
    assert probe["uid"] == 1000 and probe["limit"] == 0 and probe["result"] == -1, probe
    assert probe["errno"] in (1, 28), probe  # EPERM or ENOSPC, never successful creation.
    print("uid1000 user namespace creation denied:", probe, flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runtime", type=Path, default=ROOT / ".amp/in/tinyarm-sim/runtime-simulator")
    parser.add_argument("--device", default="booted", help="booted iOS simulator UUID")
    args = parser.parse_args()
    BUILD.mkdir(parents=True, exist_ok=True)
    binary = BUILD / "native-rpc-host"
    subprocess.run(["xcrun", "--sdk", "iphonesimulator", "clang", "-arch", "arm64",
                    "-mios-simulator-version-min=18.0", "-std=c11", "-O2", "-pthread",
                    "-I", str(args.runtime / "include"), str(HERE / "native_rpc_host.c"),
                    str(args.runtime / "lib/libtinyarm.a"), "-o", str(binary)], check=True)
    command = ["xcrun", "simctl", "spawn", args.device, str(binary), str(PACK / "config")]
    vm = Vm(command, "native-authoring")
    try:
        check_user_namespaces(vm)
        result = vm.execute(["python3", "-c", "import os,sys,ssl,sqlite3,ctypes; print(os.getuid(),os.getgid(),os.getcwd()); print(sys.stdin.read())"], "x" * 12000)
        assert result["exitCode"] == 0 and result["stdout"].startswith("1000 1000 /workspace/kit\n"), result
        assert "x" * 12000 in result["stdout"], result
        assert vm.execute(["sh", "-c", "printf shell-ok; printf error >&2; exit 7"])["exitCode"] == 7
        manifest = {"apiVersion": 1, "name": "RPC fixture", "description": "Transport test only",
                    "fields": [{"key": "value", "label": "Value", "type": "integer"}],
                    "entrypoint": ["sh", "entry.sh"]}
        source = ("import pathlib,subprocess; p=pathlib.Path('.'); (p/'kit.json').write_text(%r); "
                  "(p/'entry.sh').write_text('cat\\n'); "
                  "subprocess.run(['git','init'],check=True); subprocess.run(['git','add','.'],check=True); "
                  "subprocess.run(['git','-c','user.name=Fixture','-c','user.email=fixture@invalid',"
                  "'commit','-m','fixture'],check=True)" % json.dumps(manifest))
        result = vm.execute(["python3", "-c", source])
        assert result["exitCode"] == 0, result
        response = vm.call("export")
        assert response["ok"], response
        artifact = response["artifact"]
        assert set(artifact) == {"revision", "files"} and len(artifact["revision"]) == 40, artifact
        assert {f["path"] for f in artifact["files"]} == {"kit.json", "entry.sh"}, artifact
        assert not vm.call("import", artifact=artifact)["ok"]
        vm.execute(["sh", "-c", "printf dirty >> entry.sh"])
        assert not vm.call("export")["ok"]
        bounded = vm.execute(["python3", "-c", "import os; os.write(1,b'x'*100000)"])
        assert bounded["truncated"] and len(bounded["stdout"].encode()) <= 32768, bounded
        assert vm.execute(["sh", "-c", "sleep 5"], timeout=100)["exitCode"] == 124
        print("authoring: real Python/shared libraries, sh, Git commit, export, dirty rejection, bounds, timeout OK", flush=True)
    finally:
        vm.close()
    # A different OS process, fresh VM, fresh RAM, no authoring filesystem reuse.
    vm = Vm(command, "native-private")
    try:
        response = vm.call("import", artifact=artifact)
        assert response["ok"], response
        response = vm.execute(["sh", "entry.sh"], '{"private":"transport fixture"}')
        assert response["exitCode"] == 0 and response["stdout"] == '{"private":"transport fixture"}', response
        assert vm.execute(["sh", "-c", "test ! -e .git; printf fresh"])["stdout"] == "fresh"
        print("private: artifact import and stdin execution in a fresh VM OK", flush=True)
    finally:
        vm.close()


if __name__ == "__main__":
    main()
