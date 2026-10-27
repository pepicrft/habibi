#!/usr/bin/env python3
"""Run a disposable PostgreSQL cluster inside the real simulator Linux guest."""

import argparse
import json
import os
from pathlib import Path
import subprocess
import time

from smoke_native import BUILD, HERE, ROOT, Vm


PREFIX = "/usr/libexec/postgresql17"
DATA = "/workspace/home/pgdata"
SOCKET = "/workspace/home/pgsocket"
OPTIONS = (f"-F -k {SOCKET} -c listen_addresses='' -c shared_buffers=8MB "
           "-c max_connections=5 -c max_worker_processes=0 -c autovacuum=off "
           "-c dynamic_shared_memory_type=mmap -c wal_buffers=64kB "
           "-c min_wal_size=2MB -c max_wal_size=16MB")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--device", default="booted")
    parser.add_argument("--runtime", type=Path, default=ROOT / ".amp/in/tinyarm-sim/runtime-simulator")
    args = parser.parse_args()
    subprocess.run(["git", "check-ignore", "--quiet", ".amp/in/tinyarm-sim/guest-build/probe"], cwd=ROOT, check=True)
    binary = BUILD / "postgres-rpc-host"
    subprocess.run(["xcrun", "--sdk", "iphonesimulator", "clang", "-arch", "arm64",
                    "-mios-simulator-version-min=18.0", "-std=c11", "-O2", "-pthread",
                    "-I", str(args.runtime / "include"), str(HERE / "native_rpc_host.c"),
                    str(args.runtime / "lib/libtinyarm.a"), "-o", str(binary)], check=True)
    vm = Vm(["xcrun", "simctl", "spawn", args.device, str(binary),
             str(ROOT / ".amp/in/tinyarm-sim/coding-pack/config")], "postgres", boot_timeout=300)
    evidence = {"physicalDevice": False, "durableStorage": False, "externalNetwork": False, "steps": []}

    def execute(argv):
        started = time.monotonic()
        result = vm.call("exec", argv=argv, timeoutMs=120000, receive_timeout=150)
        evidence["steps"].append({"argv": argv, "seconds": round(time.monotonic() - started, 3), **result})
        print(json.dumps(result), flush=True)
        assert result["ok"] and result["exitCode"] == 0 and not result["truncated"], result
        return result

    try:
        execute(["sh", "-c", f"set -e; id; {PREFIX}/postgres --version; mkdir -m 700 {SOCKET}; "
                 f"{PREFIX}/initdb -D {DATA} --no-locale --encoding=UTF8 --auth=trust --wal-segsize=1 --no-sync"])
        for sql, expected in (("BEGIN; CREATE TABLE invoice(price integer, quantity integer); "
                               "INSERT INTO invoice VALUES (199,3),(284,2); COMMIT; "
                               "SELECT sum(price*quantity) FROM invoice; "
                               "BEGIN; DELETE FROM invoice; ROLLBACK; SELECT count(*) FROM invoice;", "1165\n2\n"),
                              ("SELECT sum(price*quantity), count(*) FROM invoice;", "1165|2\n")):
            # Keep server and client in one exec: the RPC intentionally kills
            # all uid1000 descendants between commands, even detached daemons.
            command = (f"set -e; export PATH={PREFIX}:$PATH; "
                       f"trap 'pg_ctl -D {DATA} -m immediate stop >/dev/null 2>&1 || true' EXIT; "
                       f"pg_ctl -D {DATA} -l /workspace/home/postgres.log -o \"{OPTIONS}\" -w start >/dev/null || "
                       "{ cat /workspace/home/postgres.log; exit 1; }; "
                       f"psql -X -Atq -v ON_ERROR_STOP=1 -h {SOCKET} -d postgres -c '{sql}'; "
                       f"pg_ctl -D {DATA} -m fast -w stop >/dev/null")
            assert execute(["sh", "-c", command])["stdout"] == expected
        execute(["sh", "-c", f"test ! -e {DATA}/postmaster.pid; test ! -e {SOCKET}/.s.PGSQL.5432; "
                 f"rm -rf {DATA} {SOCKET} /workspace/home/postgres.log"])
        evidence["passed"] = True
    finally:
        vm.close()
        path = BUILD / "postgres-result.json"
        with os.fdopen(os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600), "w") as file:
            json.dump(evidence, file, indent=2)
        print("Evidence:", path, flush=True)


if __name__ == "__main__":
    main()
