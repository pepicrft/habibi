#!/usr/bin/env python3
"""Real simulator coding task; fixture inference by default, opt-in cloud model."""

import argparse
import http.client
import hashlib
import json
import os
from pathlib import Path
import subprocess
import time
import uuid

from smoke_native import BUILD, HERE, ROOT, Vm, check_user_namespaces
from network_policy import NetworkPolicy


FILES = {
    "invoice.mjs": "export const total = lines => lines.reduce((sum, line) => sum + line.price, 0);\n",
    "invoice.rb": "def total(lines)\n  lines.sum { |line| line.fetch(:price) }\nend\n",
    "test-invoice.mjs": """import assert from 'node:assert/strict';
import { total } from './invoice.mjs';
assert.equal(total([{price:199,quantity:3},{price:284,quantity:2}]), 1165);
assert.equal(total([]), 0);
assert.equal(total([{price:0,quantity:8},{price:500,quantity:0}]), 0);
console.log('node invoice cases passed');
""",
    "test-invoice.rb": """require_relative 'invoice'
raise 'asymmetric quantities' unless total([{price:199,quantity:3},{price:284,quantity:2}]) == 1165
raise 'empty invoice' unless total([]) == 0
raise 'zero quantity/price' unless total([{price:0,quantity:8},{price:500,quantity:0}]) == 0
puts 'ruby invoice cases passed'
""",
}
TASK = "Fix invoice totals in both languages: sum price * quantity, in integer cents. Keep tests unchanged, run them, and commit the fix locally."


def fixture_answers():
    fixed = {"invoice.mjs": FILES["invoice.mjs"].replace("line.price", "line.price * line.quantity"),
             "invoice.rb": FILES["invoice.rb"].replace("line.fetch(:price)", "line.fetch(:price) * line.fetch(:quantity)")}
    for argv, stdin in [
        (["sh", "-c", "cat invoice.mjs invoice.rb; node test-invoice.mjs; ruby test-invoice.rb"], ""),
        (["python3", "-c", "import json,pathlib,sys; [pathlib.Path(k).write_text(v) for k,v in json.load(sys.stdin).items()]"], json.dumps(fixed)),
        (["sh", "-c", "node test-invoice.mjs && ruby test-invoice.rb && git diff && git add invoice.mjs invoice.rb && git -c user.name=Fixture -c user.email=fixture@invalid commit -m 'Fix invoice quantities'"], ""),
    ]:
        yield {"kind": "exec", "argv": argv, "stdin": stdin, "reply": ""}
    yield {"kind": "reply", "argv": [], "stdin": "", "reply": "Fixture task finished"}


def infer(state):
    # Only the host reads this token. The guest emits an inference request as data.
    token = json.loads((ROOT / ".amp/in/tinyarm-coding/bridge.json").read_text())["token"]
    connection = http.client.HTTPConnection("127.0.0.1", 8085, timeout=110)
    try:
        connection.request("POST", "/step", json.dumps({"instructions": state["instructions"],
                                                       "history": state["history"]}),
                           {"Content-Type": "application/json", "Authorization": "Bearer " + token})
        response = connection.getresponse()
        body = response.read(256 * 1024)
        if response.status != 200:
            raise RuntimeError("Inference bridge returned HTTP %s" % response.status)
        return json.loads(body)
    finally:
        connection.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--device", default="booted")
    parser.add_argument("--runtime", type=Path, default=ROOT / ".amp/in/tinyarm-sim/runtime-simulator")
    parser.add_argument("--model", action="store_true", help="disclose synthetic task/source/results to the cloud through bridge.mjs --coding")
    parser.add_argument("--network", action="store_true", help="approve read-only octocat/Hello-World clone and its hash-pinned README download")
    parser.add_argument("--record", action="store_true", help="record bounded network bodies and file syscall traces; logs may contain source/page data")
    args = parser.parse_args()
    subprocess.run(["git", "check-ignore", "--quiet", ".amp/in/tinyarm-sim/guest-build/probe"], cwd=ROOT, check=True)
    BUILD.mkdir(parents=True, exist_ok=True)
    binary = BUILD / "coding-rpc-host"
    subprocess.run(["xcrun", "--sdk", "iphonesimulator", "clang", "-arch", "arm64",
                    "-mios-simulator-version-min=18.0", "-std=c11", "-O2", "-pthread",
                    "-I", str(args.runtime / "include"), str(HERE / "native_rpc_host.c"),
                    str(args.runtime / "lib/libtinyarm.a"), "-o", str(binary)], check=True)
    mode = "model" if args.model else "fixture"
    evidence = {"mode": mode, "physicalDevice": False, "measurements": []}
    repository = "https://github.com/octocat/Hello-World.git"
    download = "https://raw.githubusercontent.com/octocat/Hello-World/master/README"
    recording = BUILD / ("recording-" + uuid.uuid4().hex) if args.record else None
    if recording is not None:
        evidence["recordingDirectory"] = str(recording)
    policy = NetworkPolicy(repositories=[repository] if args.network else [], downloads={
        download: hashlib.sha256(b"Hello World!\n").hexdigest()} if args.network else {}, record_to=recording)
    started = time.monotonic()
    vm = Vm(["xcrun", "simctl", "spawn", args.device, str(binary),
             str(ROOT / ".amp/in/tinyarm-sim/coding-pack/config")], "coding-" + mode,
            network=policy, boot_timeout=300)
    evidence["bootSeconds"] = round(time.monotonic() - started, 3)

    def execute(argv, stdin="", success=True):
        start = time.monotonic()
        result = vm.call("exec", argv=argv, stdin=stdin, timeoutMs=120000,
                         traceFiles=args.record, receive_timeout=140)
        assert result["ok"], result
        evidence["measurements"].append({"argv": argv, "seconds": round(time.monotonic() - start, 3), **result})
        print(argv[:2], result["exitCode"], result["stdout"][:200], flush=True)
        assert not result["truncated"], result
        if success:
            assert result["exitCode"] == 0, result
        return result

    def turn(body):
        return json.loads(execute(["node", "/opt/habibi/coding-harness.mjs"], json.dumps(body))["stdout"])

    try:
        check_user_namespaces(vm)
        versions = execute(["sh", "-c", "uname -sm; id; git --version; node --version; ruby --version; bundle --version"])
        assert "Linux aarch64" in versions["stdout"] and "uid=1000" in versions["stdout"], versions
        setup = "import json,pathlib,sys; [pathlib.Path(k).write_text(v) for k,v in json.load(sys.stdin).items()]"
        execute(["python3", "-c", setup], json.dumps(FILES))
        execute(["sh", "-c", "git init -q && git add . && git -c user.name=Fixture -c user.email=fixture@invalid commit -qm baseline"])
        for argv in (["node", "test-invoice.mjs"], ["ruby", "test-invoice.rb"]):
            result = execute(argv, success=False)
            assert result["exitCode"] not in (0, 124), result
            assert "AssertionError" in result["stderr"] or "asymmetric quantities" in result["stderr"], result
        state = turn({"task": TASK})
        scripted = iter(fixture_answers())
        for _ in range(9):
            answer = infer(state) if args.model else next(scripted)
            state = turn({"answer": answer})
            if state["done"]:
                break
        assert state["done"], "Harness did not finish within its turn budget"
        evidence["session"] = state
        # These checks, not the model's reply, determine whether the task worked.
        execute(["node", "test-invoice.mjs"])
        execute(["ruby", "test-invoice.rb"])
        check = execute(["sh", "-c", "git status --porcelain; git rev-list --count HEAD; git diff HEAD~1 --name-only; git log -1 --format=%H"])
        lines = check["stdout"].splitlines()
        assert lines[0] == "2" and lines[1:3] == ["invoice.mjs", "invoice.rb"], check
        assert len(lines) == 4 and len(lines[3]) == 40, check
        verify = "import json,pathlib,sys; files=json.load(sys.stdin); assert all(pathlib.Path(k).read_text()==v for k,v in files.items())"
        execute(["python3", "-c", verify], json.dumps({k: v for k, v in FILES.items() if k.startswith("test-")}))
        # Session state survives Node process exit, but terminal sessions reject replay.
        result = execute(["node", "/opt/habibi/coding-harness.mjs"], json.dumps({"answer": {"kind": "exec", "argv": ["sh", "-c", "touch replayed"], "stdin": "", "reply": ""}}), success=False)
        assert result["exitCode"] != 0 and "already finished" in result["stderr"], result
        execute(["sh", "-c", "test ! -e replayed; test -f /workspace/home/coding-session.json; test ! -e /workspace/home/coding-session.json.tmp"])
        if args.record:
            result = execute(["sh", "-c", "id -u; printf audit-data > /workspace/home/audit-created; cat /workspace/home/audit-created; mv /workspace/home/audit-created /workspace/home/audit-renamed; rm /workspace/home/audit-renamed"])
            assert result["stdout"] == "1000\naudit-data", result
            assert not result["fileTraceTruncated"], result
            for operation in ("audit-created", "audit-renamed", "O_RDONLY", "O_WRONLY", "rename", "unlink"):
                assert operation in result["fileTrace"], operation
        # Git speaks HTTP only to a guest-local adapter. The host approves exact
        # HTTPS repository endpoints; there is still no guest NIC or host share.
        denial = """import http.client,socket
for path,method in [('/https/github.com/other/repo.git/info/refs?service=git-upload-pack','GET'),
                    ('/https/github.com/octocat/Hello-World.git/git-receive-pack','POST'),
                    ('/https/127.0.0.1/private','GET')]:
 c=http.client.HTTPConnection('127.0.0.1',8080,timeout=15)
 c.request(method,path,body=b''); r=c.getresponse(); assert r.status==403; r.read(); c.close()
s=socket.socket(); s.settimeout(2)
try:
 s.connect(('93.184.216.34',443)); raise AssertionError('direct egress unexpectedly worked')
except OSError as e:
 assert e.errno==101, e
finally: s.close()
print('unapproved repo, push, localhost and direct egress denied')
"""
        execute(["python3", "-c", denial])
        clone_url = "http://127.0.0.1:8080/https/github.com/octocat/Hello-World.git"
        if args.network:
            execute(["git", "-c", "core.hooksPath=/dev/null", "clone", "--depth=1", clone_url, "/workspace/home/checkout"])
            cloned = execute(["sh", "-c", "cat /workspace/home/checkout/README; git -C /workspace/home/checkout rev-parse HEAD"])
            assert cloned["stdout"].startswith("Hello World!\n"), cloned
            fetch = "import urllib.request; data=urllib.request.urlopen('http://127.0.0.1:8080/https/raw.githubusercontent.com/octocat/Hello-World/master/README').read(); assert data==b'Hello World!\\n'; print('hash-pinned download passed')"
            execute(["python3", "-c", fetch])
        else:
            result = execute(["git", "clone", "--depth=1", clone_url, "/workspace/home/checkout"], success=False)
            assert result["exitCode"] != 0 and "403" in result["stderr"], result
        quota = """import errno,os,pathlib,shutil
w=os.statvfs('/workspace'); t=os.statvfs('/tmp')
assert w.f_blocks*w.f_frsize==64*1024*1024 and w.f_files==4096, w
assert t.f_blocks*t.f_frsize==32*1024*1024 and t.f_files==2048, t
for kind in ('bytes','inodes'):
 p=pathlib.Path('/workspace/home/quota-'+kind); p.mkdir()
 try:
  try:
   for n in range(5000 if kind=='inodes' else 80):
    with (p/str(n)).open('wb') as f:
     if kind=='bytes': f.write(b'x'*1024*1024)
   raise AssertionError('quota was not enforced')
  except OSError as e:
   assert e.errno==errno.ENOSPC, e
   print(kind+' quota enforced at '+str(n)+' files')
 finally: shutil.rmtree(p)
try:
 pathlib.Path('/opt/habibi/forbidden').write_text('no'); raise AssertionError('root filesystem writable')
except PermissionError: pass
assert not any(' 9p ' in line for line in pathlib.Path('/proc/mounts').read_text().splitlines())
assert [p.name for p in pathlib.Path('/sys/class/net').iterdir()]==['lo']
print('guest-only storage, byte/inode quotas and cleanup passed')
"""
        execute(["python3", "-c", quota])
        if args.record:
            for entry in policy.audit:
                for kind in ("request", "response"):
                    if kind not in entry:
                        continue
                    path = recording / entry[kind]["file"]
                    data = path.read_bytes()
                    assert len(data) == entry[kind]["bytes"]
                    assert hashlib.sha256(data).hexdigest() == entry[kind]["sha256"]
                    assert path.stat().st_mode & 0o777 == 0o600
        evidence["passed"] = True
        print(mode + ": coding session, Node/Ruby tests, Git commit, network policies and storage quotas passed", flush=True)
    finally:
        vm.close()
        evidence["networkAudit"] = policy.audit
        output = BUILD / ("coding-" + mode + "-result.json")
        with os.fdopen(os.open(output, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600), "w") as file:
            file.write(json.dumps(evidence, indent=2) + "\n")
        print("Evidence:", output, flush=True)


if __name__ == "__main__":
    main()
