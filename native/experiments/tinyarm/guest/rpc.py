#!/usr/bin/env python3
"""Unaudited simulator-only JSONL service. NOT a general hostile-code sandbox."""

import argparse
import ctypes
import hashlib
import json
import math
import os
from pathlib import Path
import re
import resource
import selectors
import shutil
import signal
import stat
import subprocess
import sys
import time
import uuid


UID = GID = 1000
REQUEST_LIMIT = 1024 * 1024
OUTPUT_LIMIT = 32 * 1024
FILE_LIMIT = 32 * 1024
ARTIFACT_LIMIT = 128 * 1024
FILE_COUNT = 128
ADDRESS_SPACE_LIMIT = 192 * 1024 * 1024
CHILD_FILE_LIMIT = 8 * 1024 * 1024
DESCRIPTOR_LIMIT = 64
EXEC_TIMEOUT_LIMIT = 20000
TRACE_AVAILABLE = False
ENV = {"PATH": "/usr/bin:/bin", "HOME": "/workspace/home", "LANG": "C.UTF-8",
       "PYTHONIOENCODING": "utf-8", "PYTHONDONTWRITEBYTECODE": "1",
       "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null",
       "GIT_TERMINAL_PROMPT": "0"}
GIT = ["/usr/bin/git", "--no-optional-locks", "-c", "core.hooksPath=/dev/null",
       "-c", "core.fsmonitor=false", "-c", "core.pager=cat", "-c", "core.attributesFile=/dev/null"]


def require(condition, message):
    if not condition:
        raise ValueError(message)


def prctl(option, value):
    libc = ctypes.CDLL(None, use_errno=True)
    if libc.prctl(option, value, 0, 0, 0) != 0:
        raise OSError(ctypes.get_errno(), "prctl failed")


def child_setup(timeout_ms, trace=False):
    os.umask(0o022)
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    cpu = max(1, math.ceil(timeout_ms / 1000))
    resource.setrlimit(resource.RLIMIT_CPU, (cpu, cpu + 1))
    resource.setrlimit(resource.RLIMIT_AS, (ADDRESS_SPACE_LIMIT,) * 2)
    resource.setrlimit(resource.RLIMIT_FSIZE, (CHILD_FILE_LIMIT,) * 2)
    resource.setrlimit(resource.RLIMIT_NOFILE, (DESCRIPTOR_LIMIT,) * 2)
    resource.setrlimit(resource.RLIMIT_NPROC, (32, 32))
    if os.geteuid() == 0 and not trace:
        os.setgroups([])
        os.setgid(GID)
        os.setuid(UID)
    require((trace and os.geteuid() == 0) or (os.getuid() == UID and os.getgid() == GID),
            "child must be uid/gid 1000 (or the root tracer)")
    prctl(38, 1)  # PR_SET_NO_NEW_PRIVS, inherited by every descendant.


def cleanup_children():
    """Dedicated disposable VM only: kill *all* uid1000 tasks, even new sessions."""
    for _ in range(4):
        found = False
        for entry in os.scandir("/proc"):
            if not entry.name.isdigit():
                continue
            try:
                status = (Path(entry.path) / "status").read_text()
                uid_line = next(line for line in status.splitlines() if line.startswith("Uid:"))
                if str(UID) in uid_line.split()[1:]:
                    os.kill(int(entry.name), signal.SIGKILL)
                    found = True
            except (OSError, StopIteration):
                pass
        while True:
            try:
                pid, _ = os.waitpid(-1, os.WNOHANG)
                if pid == 0:
                    break
            except ChildProcessError:
                break
        if not found:
            return
        time.sleep(0.01)


def capture(argv, cwd, timeout_ms, stdin=b"", limit=OUTPUT_LIMIT, drop=True, trace=False):
    """Drain pipes without buffering unbounded output or blocking on stdin."""
    if trace:
        require(drop and TRACE_AVAILABLE, "file tracing requires the coding guest")
        # Root tracer owns the log; strace drops the actual command to kit.
        # The process/file/time limits still apply, and cleanup kills tracees.
        argv = ["/usr/bin/strace", "-f", "-qq", "-u", "kit", "-e", "trace=%file",
                "-o", "/run/habibi-files.trace", "--"] + argv
    process = subprocess.Popen(argv, cwd=cwd, env=ENV, stdin=subprocess.PIPE,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                               start_new_session=True, close_fds=True,
                               preexec_fn=(lambda: child_setup(timeout_ms, trace)) if drop else None)
    output = [bytearray(), bytearray()]
    truncated, timed_out, sent = False, False, 0
    deadline = time.monotonic() + timeout_ms / 1000
    try:
        with selectors.DefaultSelector() as selector:
            for pipe, kind in ((process.stdout, 0), (process.stderr, 1)):
                os.set_blocking(pipe.fileno(), False)
                selector.register(pipe, selectors.EVENT_READ, kind)
            if stdin:
                os.set_blocking(process.stdin.fileno(), False)
                selector.register(process.stdin, selectors.EVENT_WRITE, 2)
            else:
                process.stdin.close()
            while selector.get_map():
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    timed_out = True
                    break
                for key, _ in selector.select(min(remaining, 0.05)):
                    if key.data == 2:
                        try:
                            sent += os.write(key.fd, stdin[sent:sent + 4096])
                        except BrokenPipeError:
                            sent = len(stdin)
                        if sent == len(stdin):
                            selector.unregister(key.fileobj)
                            key.fileobj.close()
                        continue
                    try:
                        data = os.read(key.fd, 4096)
                    except BlockingIOError:
                        continue
                    if not data:
                        selector.unregister(key.fileobj)
                        key.fileobj.close()
                        continue
                    room = max(0, limit - len(output[0]) - len(output[1]))
                    output[key.data].extend(data[:room])
                    truncated |= len(data) > room
                # A detached child may keep a pipe open after the leader exits.
                if process.poll() is not None:
                    try:
                        os.killpg(process.pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
            if not timed_out:
                try:
                    process.wait(timeout=max(0.001, deadline - time.monotonic()))
                except subprocess.TimeoutExpired:
                    timed_out = True
    finally:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        if drop:
            cleanup_children()
        # No unbounded wait: the VM lifecycle deadline remains a host duty.
        try:
            process.wait(timeout=1)
        except (subprocess.TimeoutExpired, ChildProcessError):
            pass
        for pipe in (process.stdin, process.stdout, process.stderr):
            pipe.close()
    code = 124 if timed_out else process.returncode
    if code is None:
        code = 124
    elif code < 0:
        code = 128 - code
    return code, bytes(output[0]), bytes(output[1]), truncated


def utf8_output(stdout, stderr, truncated):
    rendered, room = [], OUTPUT_LIMIT
    for value in (stdout, stderr):
        encoded = value.decode("utf-8", "replace").encode("utf-8")
        clipped = encoded[:room].decode("utf-8", "ignore")
        rendered.append(clipped)
        truncated |= len(encoded) > room
        room -= len(clipped.encode("utf-8"))
    return rendered[0], rendered[1], truncated


def safe_path(value):
    require(isinstance(value, str) and 0 < len(value.encode("utf-8")) <= 240, "invalid file path")
    require(not value.startswith("/") and "\\" not in value and ":" not in value,
            "unsafe file path")
    parts = value.split("/")
    require(all(part not in ("", ".", "..") and part.lower() != ".git" for part in parts),
            "unsafe file path")
    require(not any(ord(char) < 32 or ord(char) == 127 for char in value), "control character in path")
    return parts


def validate_manifest(content):
    manifest = json.loads(content)
    require(isinstance(manifest, dict) and type(manifest.get("apiVersion")) is int
            and manifest["apiVersion"] == 1, "kit.json apiVersion must be 1")
    for key, maximum in (("name", 120), ("description", 4096)):
        require(isinstance(manifest.get(key), str) and 0 < len(manifest[key]) <= maximum,
                "invalid kit.json " + key)
    fields = manifest.get("fields")
    require(isinstance(fields, list) and len(fields) <= 64, "invalid kit.json fields")
    seen = set()
    for field in fields:
        require(isinstance(field, dict), "invalid manifest field")
        key = field.get("key")
        require(isinstance(key, str) and re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]{0,63}", key)
                and key not in seen, "invalid/duplicate field key")
        seen.add(key)
        require(isinstance(field.get("label"), str) and 0 < len(field["label"]) <= 120,
                "invalid field label")
        require(field.get("type") in ("string", "number", "integer"), "invalid field type")
        for bound in ("min", "max"):
            if bound in field:
                require(type(field[bound]) in (int, float) and math.isfinite(field[bound]), "invalid field bound")
        if "min" in field and "max" in field:
            require(field["min"] <= field["max"], "invalid field range")
        if "unit" in field:
            require(isinstance(field["unit"], str) and len(field["unit"]) <= 80, "invalid field unit")
    entrypoint = manifest.get("entrypoint")
    require(isinstance(entrypoint, list) and 0 < len(entrypoint) <= 32
            and all(isinstance(arg, str) and "\x00" not in arg and len(arg) <= 4096 for arg in entrypoint)
            and entrypoint[0], "invalid kit.json entrypoint")


def validate_artifact(artifact):
    require(isinstance(artifact, dict), "artifact must be an object")
    require(isinstance(artifact.get("revision"), str)
            and re.fullmatch(r"[0-9a-f]{40}", artifact["revision"]), "invalid revision")
    files = artifact.get("files")
    require(isinstance(files, list) and 0 < len(files) <= FILE_COUNT, "invalid artifact file count")
    seen, total = {}, 0
    for file in files:
        require(isinstance(file, dict), "invalid artifact file")
        path, content = file.get("path"), file.get("content")
        safe_path(path)
        require(path not in seen and isinstance(content, str), "duplicate path or invalid content")
        length = len(content.encode("utf-8"))
        require(length <= FILE_LIMIT, "file exceeds 32KiB")
        total += length
        require(total <= ARTIFACT_LIMIT, "artifact exceeds 128KiB")
        seen[path] = content
    for path in seen:
        parts = path.split("/")
        require(not any("/".join(parts[:end]) in seen for end in range(1, len(parts))), "file/directory collision")
    require("kit.json" in seen, "artifact must contain kit.json")
    validate_manifest(seen["kit.json"])
    return seen


def read_regular(root_fd, path):
    parts = safe_path(path)
    directory = os.dup(root_fd)
    try:
        for part in parts[:-1]:
            child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=directory)
            os.close(directory)
            directory = child
        fd = os.open(parts[-1], os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=directory)
        with os.fdopen(fd, "rb") as file:
            info = os.fstat(file.fileno())
            require(stat.S_ISREG(info.st_mode) and info.st_nlink == 1, "not a regular unlinked-from-others file")
            require(info.st_size <= FILE_LIMIT, "file exceeds 32KiB")
            content = file.read(FILE_LIMIT + 1)
            require(len(content) <= FILE_LIMIT, "file exceeds 32KiB")
            return content.decode("utf-8")
    finally:
        os.close(directory)


def export_worker(kit):
    # This entire worker, including all git config parsing, runs as uid1000.
    def git(*args):
        code, out, err, clipped = capture(GIT + list(args), kit, 10000, limit=256 * 1024, drop=False)
        require(code == 0 and not clipped, "git check failed: " + err.decode("utf-8", "replace")[:200])
        return out

    require(os.geteuid() == UID, "export worker must be unprivileged")
    require((kit / ".git").is_dir() and not (kit / ".git").is_symlink(), "standalone git repository required")
    require(git("rev-parse", "--show-toplevel").decode().strip() == str(kit), "repository root must be kit")
    revision = git("rev-parse", "--verify", "HEAD^{commit}").decode().strip()
    require(re.fullmatch(r"[0-9a-f]{40}", revision), "40-character Git revision required")
    require(not git("status", "--porcelain=v1", "--untracked-files=all", "--ignored=matching"),
            "repository must be clean and committed (including ignored files)")
    records = git("ls-tree", "-rz", "--full-tree", "HEAD").split(b"\0")
    require(len(records) - 1 <= FILE_COUNT, "too many tracked files")
    files = []
    root_fd = os.open(str(kit), os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        for record in records:
            if not record:
                continue
            metadata, raw_path = record.split(b"\t", 1)
            mode, kind, object_id = metadata.split(b" ")
            require(mode in (b"100644", b"100755") and kind == b"blob", "symlinks and submodules are forbidden")
            path = raw_path.decode("utf-8")
            content = read_regular(root_fd, path)
            # Read committed bytes, not a worktree that Git attributes/filters can
            # make appear clean while its content differs. Hash without filters.
            raw = content.encode("utf-8")
            hashed = hashlib.sha1(b"blob " + str(len(raw)).encode() + b"\0" + raw).hexdigest().encode()
            require(hashed == object_id, "worktree differs from committed bytes")
            files.append({"path": path, "content": content})
            require(sum(len(file["content"].encode("utf-8")) for file in files) <= ARTIFACT_LIMIT,
                    "artifact exceeds 128KiB")
    finally:
        os.close(root_fd)
    artifact = {"revision": revision, "files": files}
    validate_artifact(artifact)
    return artifact


class Service:
    def __init__(self, workspace):
        self.workspace = workspace
        self.kit = workspace / "kit"
        self.pristine = True

    def exec(self, request):
        argv = request.get("argv")
        require(isinstance(argv, list) and 0 < len(argv) <= 128
                and all(isinstance(arg, str) and "\x00" not in arg for arg in argv)
                and argv[0] and sum(len(arg.encode("utf-8")) + 1 for arg in argv) <= 16384,
                "argv must be a bounded nonempty string array")
        timeout = request.get("timeoutMs")
        require(type(timeout) is int and 1 <= timeout <= EXEC_TIMEOUT_LIMIT,
                "timeoutMs must be 1..%s" % EXEC_TIMEOUT_LIMIT)
        stdin = request.get("stdin", "")
        require(isinstance(stdin, str) and len(stdin.encode("utf-8")) <= ARTIFACT_LIMIT, "stdin exceeds 128KiB or is not a string")
        trace = request.get("traceFiles", False)
        require(type(trace) is bool and (not trace or TRACE_AVAILABLE), "file tracing is unavailable")
        log = Path("/run/habibi-files.trace")
        try:
            code, out, err, clipped = capture(argv, self.kit, timeout, stdin.encode("utf-8"), trace=trace)
            audit = {}
            if trace:
                with log.open("rb") as file:
                    recorded = file.read(256 * 1024 + 1)
                audit = {"fileTrace": recorded[:256 * 1024].decode("utf-8", "replace"),
                         "fileTraceTruncated": len(recorded) > 256 * 1024}
        finally:
            if trace:
                log.unlink(missing_ok=True)
        out, err, clipped = utf8_output(out, err, clipped)
        return {"exitCode": code, "stdout": out, "stderr": err, "truncated": clipped, **audit}

    def export(self):
        code, out, err, clipped = capture([sys.executable, "-I", "-B", str(Path(__file__).resolve()),
                                          "--export-worker", "--workspace", str(self.workspace)],
                                         self.kit, 60000, limit=REQUEST_LIMIT)
        require(code == 0 and not clipped,
                "export failed (exit %s, truncated=%s): " % (code, clipped)
                + err.decode("utf-8", "replace")[:300])
        artifact = json.loads(out)
        validate_artifact(artifact)
        return {"artifact": artifact}

    def import_artifact(self, artifact):
        require(self.pristine, "import is only permitted as the first operation in a fresh private VM")
        files = validate_artifact(artifact)
        require(not any(self.kit.iterdir()), "import requires an empty fresh workspace")
        # Parent is root-owned; no model has run and no uid1000 processes exist.
        for name in ("kit", "home"):
            directory = self.workspace / name
            require(directory.is_dir() and not directory.is_symlink(), "invalid fresh workspace")
            shutil.rmtree(directory)
            directory.mkdir(mode=0o755)
            os.chown(directory, UID, GID)
        for path, content in files.items():
            target = self.kit / path
            target.parent.mkdir(parents=True, exist_ok=True)
            fd = os.open(str(target), os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o644)
            with os.fdopen(fd, "wb") as file:
                file.write(content.encode("utf-8"))
                os.fchown(file.fileno(), UID, GID)
        for directory, _, _ in os.walk(self.kit):
            os.chown(directory, UID, GID)
        return {}

    def handle(self, request):
        request_id = request.get("id") if isinstance(request, dict) else None
        if not isinstance(request_id, str):
            request_id = None
        try:
            require(isinstance(request, dict), "request must be an object")
            require(isinstance(request_id, str) and len(request_id) == 36
                    and str(uuid.UUID(request_id)) == request_id.lower(), "id must be a UUID string")
            op = request.get("op")
            if op == "exec":
                self.pristine = False
                result = self.exec(request)
            elif op == "export":
                self.pristine = False
                result = self.export()
            elif op == "import":
                result = self.import_artifact(request.get("artifact"))
                self.pristine = False
            else:
                raise ValueError("unknown op")
            return {"id": request_id, "ok": True, **result}
        except Exception as error:
            return {"id": request_id, "ok": False, "error": str(error)[:500]}


def send(value):
    sys.stdout.buffer.write(json.dumps(value, ensure_ascii=True, separators=(",", ":"), allow_nan=False).encode() + b"\n")
    sys.stdout.buffer.flush()


def reject_constant(value):
    raise ValueError("non-JSON number: " + value)


def serve(workspace):
    require(sys.platform == "linux" and os.geteuid() == 0, "server requires a dedicated disposable Linux VM, root")
    prctl(36, 1)  # PR_SET_CHILD_SUBREAPER (also works when testing outside PID1).
    prctl(4, 0)  # PR_SET_DUMPABLE: children cannot inspect the trusted server.
    cleanup_children()
    service = Service(workspace)
    code, out, err, clipped = capture(["/usr/bin/git", "--version"], "/", 10000)
    require(code == 0 and not clipped, "git is not usable: " + err.decode("utf-8", "replace"))
    send({"event": "ready", "protocol": 1, "python": sys.version.split()[0], "git": out.decode().strip()})
    while True:
        line = sys.stdin.buffer.readline(REQUEST_LIMIT + 1)
        if not line:
            cleanup_children()
            return
        if len(line) > REQUEST_LIMIT:
            while line and not line.endswith(b"\n"):
                line = sys.stdin.buffer.readline(REQUEST_LIMIT + 1)
            send({"id": None, "ok": False, "error": "request line exceeds 1MiB"})
            continue
        try:
            request = json.loads(line, parse_constant=reject_constant)
        except (ValueError, UnicodeError, RecursionError):
            send({"id": None, "ok": False, "error": "invalid JSON"})
            continue
        send(service.handle(request))


def main():
    global ADDRESS_SPACE_LIMIT, CHILD_FILE_LIMIT, DESCRIPTOR_LIMIT, EXEC_TIMEOUT_LIMIT, TRACE_AVAILABLE
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--workspace", type=Path, default=Path("/workspace"))
    parser.add_argument("--export-worker", action="store_true")
    parser.add_argument("--coding", action="store_true", help="opt-in Node/Ruby research limits")
    args = parser.parse_args()
    if args.coding:
        # V8 reserves large *virtual* regions even with JIT disabled. This is
        # not an 8GiB physical-memory allowance or a hard host memory boundary.
        ADDRESS_SPACE_LIMIT = 8 * 1024 * 1024 * 1024
        # BEAM's JIT ftruncates a 64MiB memfd even for `elixir --version`.
        # Workspace/tmp byte and inode quotas remain independently enforced.
        CHILD_FILE_LIMIT = 64 * 1024 * 1024
        DESCRIPTOR_LIMIT = 128  # PostgreSQL needs more than 64 usable descriptors.
        EXEC_TIMEOUT_LIMIT = 120000
        TRACE_AVAILABLE = True
        ENV["NODE_OPTIONS"] = "--jitless --max-old-space-size=64"
        ENV["ERL_FLAGS"] = "+S 1:1 +SDcpu 1 +SDio 1 +A 1 +IOt 1"
    workspace = args.workspace.resolve()
    # Startup arguments are trusted host/init parameters, never RPC fields.
    ENV["HOME"] = str(workspace / "home")
    if args.export_worker:
        try:
            send(export_worker(workspace / "kit"))
        except Exception as error:
            print(str(error)[:500], file=sys.stderr)
            sys.exit(1)
    else:
        serve(workspace)


if __name__ == "__main__":
    main()
