#!/usr/bin/env python3
"""Real Tuist sparse-clone/agent/ExUnit trial, not the full server Mix suite."""

import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import time
import uuid

from coding_smoke import infer
from network_policy import NetworkPolicy
from smoke_native import BUILD, HERE, ROOT, Vm


SOURCE = "server/lib/tuist/shards/bin_packer.ex"
TEST = "server/test/tuist/shards/bin_packer_test.exs"
RUN = ["elixir", "-r", SOURCE, "-e", "ExUnit.start(); Code.require_file(System.argv() |> hd())", TEST]
TASK = f"""This is a real shallow sparse clone of tuist/tuist at /workspace/kit.
Change only {TEST}: add one regression test showing that an explicit negative
total (-3) clamps to one shard for two units with durations 13 and 7.
Preserve every existing test and the implementation. Do not commit or push.
Read the relevant source/test context before editing. Run the test file using:
{' '.join(RUN[:4])} 'ExUnit.start(); Code.require_file(System.argv() |> hd())' {TEST}
This is standalone ExUnit, not the project's Mix test helper or full server suite.
The host independently checks the final diff and executes the tests afterward."""


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--device", default="booted")
    parser.add_argument("--runtime", type=Path, default=ROOT / ".amp/in/tinyarm-sim/runtime-simulator")
    parser.add_argument("--probe", action="store_true", help="only probe the installed toolchain")
    args = parser.parse_args()
    subprocess.run(["git", "check-ignore", "--quiet", ".amp/in/tinyarm-sim/guest-build/probe"], cwd=ROOT, check=True)
    binary = BUILD / "tuist-rpc-host"
    subprocess.run(["xcrun", "--sdk", "iphonesimulator", "clang", "-arch", "arm64",
                    "-mios-simulator-version-min=18.0", "-std=c11", "-O2", "-pthread",
                    "-I", str(args.runtime / "include"), str(HERE / "native_rpc_host.c"),
                    str(args.runtime / "lib/libtinyarm.a"), "-o", str(binary)], check=True)
    recording = BUILD / ("tuist-network-" + uuid.uuid4().hex)
    policy = NetworkPolicy(repositories=["https://github.com/tuist/tuist.git"], record_to=recording)
    evidence = {"physicalDevice": False, "fullMixSuite": False, "recordingDirectory": str(recording), "steps": []}
    vm = Vm(["xcrun", "simctl", "spawn", args.device, str(binary),
             str(ROOT / ".amp/in/tinyarm-sim/coding-pack/config")], "tuist", network=policy, boot_timeout=300)

    def execute(argv, stdin="", check=True, trace=False):
        started = time.monotonic()
        result = vm.call("exec", argv=argv, stdin=stdin, timeoutMs=120000,
                         traceFiles=trace, receive_timeout=150)
        evidence["steps"].append({"argv": argv, "seconds": round(time.monotonic() - started, 3), **result})
        print(argv[:3], json.dumps({k: v for k, v in result.items() if k != "fileTrace"})[:5000], flush=True)
        assert result["ok"], result
        if check:
            assert result["exitCode"] == 0 and not result["truncated"], result
        return result

    try:
        execute(["sh", "-c", "set -e; uname -sm; id; git --version; mise --version; elixir --version"])
        if args.probe:
            return
        execute(["git", "-c", "core.hooksPath=/dev/null", "clone", "--quiet", "--depth=1",
                 "--filter=blob:none", "--no-checkout", "--single-branch",
                 "http://127.0.0.1:8080/https/github.com/tuist/tuist.git", "."])
        execute(["git", "sparse-checkout", "set", "--no-cone", "/server/mix.exs", "/server/mix.lock",
                 "/server/config/", "/" + SOURCE, "/" + TEST])
        execute(["git", "checkout", "--quiet", "HEAD"])
        revision = execute(["git", "rev-parse", "HEAD"])["stdout"].strip()
        evidence["revision"] = revision
        baseline = execute(RUN)
        evidence["baselineTests"] = baseline["stdout"]
        # Run the actual project command too; never label standalone ExUnit as Mix.
        evidence["mixAttempt"] = execute(["sh", "-c", "cd server && mix test test/tuist/shards/bin_packer_test.exs"], check=False)
        original = execute(["cat", TEST])["stdout"]
        state = json.loads(execute(["node", "/opt/habibi/coding-harness.mjs"], json.dumps({"task": TASK}))["stdout"])
        for _ in range(9):
            answer = infer(state)
            state = json.loads(execute(["node", "/opt/habibi/coding-harness.mjs"], json.dumps({"answer": answer}), trace=True)["stdout"])
            if state["done"]:
                break
        assert state["done"], "Agent did not finish within its tool budget"
        evidence["session"] = state
        evidence["afterTests"] = execute(RUN)["stdout"]
        before = re.search(r"(\d+) tests?, 0 failures?", evidence["baselineTests"])
        after = re.search(r"(\d+) tests?, 0 failures?", evidence["afterTests"])
        assert before and after and int(after[1]) == int(before[1]) + 1, (before, after)
        names = execute(["git", "diff", "--name-only"])["stdout"].splitlines()
        assert names == [TEST], names
        changed = execute(["cat", TEST])["stdout"]
        # Every original line must remain in order; additions cannot replace tests.
        remaining = iter(changed.splitlines())
        assert all(any(line == candidate for candidate in remaining) for line in original.splitlines())
        assert "total: -3" in changed
        evidence["diff"] = execute(["git", "diff", "--", TEST])["stdout"]
        evidence["passed"] = True
    finally:
        vm.close()
        evidence["networkAudit"] = policy.audit
        path = BUILD / "tuist-result.json"
        with os.fdopen(os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600), "w") as file:
            json.dump(evidence, file, indent=2)
        print("Evidence:", path, flush=True)


if __name__ == "__main__":
    main()
