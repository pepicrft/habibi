#!/usr/bin/env python3
"""Build a deterministic, diskless aarch64 Alpine guest. No Docker or root needed."""

import argparse
import gzip
import hashlib
import io
import json
from pathlib import Path, PurePosixPath
import re
import stat
import struct
import tarfile


HERE = Path(__file__).resolve().parent
REPO = HERE.parents[3]
BUILD = REPO / ".amp/in/tinyarm-sim/guest-build"
PACK = REPO / ".amp/in/tinyarm-sim/pack"
BASE = "https://dl-cdn.alpinelinux.org/alpine/v3.22/main/aarch64"
ROOTS = {"busybox-static": "1.37.0-r20", "python3": "3.12.15-r0",
         "musl": "1.2.5-r13", "git": "2.49.1-r0"}
KERNEL = {"name": "linux-virt", "version": "6.12.114-r0"}
EPOCH = 0


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def fetch(url, target, digest=None):
    if target.exists() and (digest is None or sha256(target.read_bytes()) == digest):
        return target.read_bytes()
    print("download", url, flush=True)
    # System curl uses the platform's TLS trust store, including on macOS.
    import subprocess
    pending = target.with_suffix(target.suffix + ".part")
    subprocess.run(["curl", "--fail", "--location", "--silent", "--show-error",
                    "--retry", "3", "--max-time", "180", url, "-o", str(pending)],
                   check=True)
    data = pending.read_bytes()
    if digest is not None and sha256(data) != digest:
        pending.unlink()
        raise ValueError("SHA256 mismatch: " + url)
    pending.replace(target)
    return data


def members(data):
    # APK v2 concatenates signature, control and data gzip/tar streams.
    with tarfile.open(fileobj=io.BytesIO(data), mode="r:gz", ignore_zeros=True) as archive:
        for member in archive:
            yield member, archive.extractfile(member).read() if member.isfile() else None


def package_info(data):
    for member, content in members(data):
        if member.name == ".PKGINFO":
            info = {}
            for line in content.decode().splitlines():
                if " = " in line:
                    key, value = line.split(" = ", 1)
                    info.setdefault(key, []).append(value)
            return info
    raise ValueError("APK has no .PKGINFO")


def resolve_lock(downloads):
    """Explicit maintainer operation; default builds never consult a moving index."""
    index_path = downloads / "APKINDEX.tar.gz"
    if index_path.exists():
        index_path.unlink()
    index = fetch(BASE + "/APKINDEX.tar.gz", index_path)
    with tarfile.open(fileobj=io.BytesIO(index), mode="r:gz") as archive:
        records = archive.extractfile("APKINDEX").read().decode().strip().split("\n\n")
    packages, providers = {}, {}
    for record in records:
        fields = dict(line.split(":", 1) for line in record.splitlines() if ":" in line)
        if fields.get("A") not in ("aarch64", "noarch"):
            continue
        packages[fields["P"]] = fields
        for provide in fields.get("p", "").split():
            providers.setdefault(re.split(r"[=<>~]", provide)[0], []).append(fields["P"])
    selected, pending = {}, list(ROOTS)
    while pending:
        dependency = pending.pop(0)
        if dependency.startswith("!"):
            raise ValueError("unhandled dependency conflict: " + dependency)
        name = re.split(r"[=<>~]", dependency)[0]
        if name not in packages:
            choices = providers.get(name, [])
            if len(choices) != 1:
                raise ValueError("ambiguous/missing provider for %s: %s" % (name, choices))
            name = choices[0]
        if name in selected:
            continue
        package = packages[name]
        if name in ROOTS and package["V"] != ROOTS[name]:
            raise ValueError("pinned root no longer in current index: " + name)
        selected[name] = package
        pending.extend(package.get("D", "").split())
    # The kernel's initramfs-generator dependency is deliberately not installed:
    # this builder supplies its own init and builds newc, without running apk scripts.
    if packages[KERNEL["name"]]["V"] != KERNEL["version"]:
        raise ValueError("pinned kernel no longer in current index")
    selected[KERNEL["name"]] = packages[KERNEL["name"]]
    locked = []
    for name, package in sorted(selected.items()):
        filename = "%s-%s.apk" % (name, package["V"])
        data = fetch(BASE + "/" + filename, downloads / filename)
        info = package_info(data)
        if info["pkgname"] != [name] or info["pkgver"] != [package["V"]]:
            raise ValueError("package metadata mismatch")
        locked.append({"name": name, "version": package["V"], "url": BASE + "/" + filename,
                       "sha256": sha256(data), "dependencies": info.get("depend", []),
                       "provides": info.get("provides", [])})
    lock = {"format": 1, "architecture": "aarch64", "repository": BASE,
            "indexSha256": sha256(index), "roots": ROOTS, "kernel": KERNEL,
            "packages": locked}
    (HERE / "apk-lock.json").write_text(json.dumps(lock, indent=2, sort_keys=True) + "\n")
    return lock


def safe_name(name):
    path = PurePosixPath(name)
    if path.is_absolute() or ".." in path.parts or "\x00" in name:
        raise ValueError("unsafe APK path: " + name)
    return str(path)


def assemble(lock, downloads):
    # Build an in-memory tree, not a host extraction: APK absolute symlinks must
    # never redirect writes into the host filesystem. Never execute APK scripts.
    tree = {}
    hardlinks = {}
    image, module = None, None
    for package in lock["packages"]:
        data = fetch(package["url"], downloads / package["url"].rsplit("/", 1)[1], package["sha256"])
        info = package_info(data)
        if info["pkgname"] != [package["name"]] or info["pkgver"] != [package["version"]]:
            raise ValueError("locked metadata mismatch")
        for member, content in members(data):
            name = safe_name(member.name)
            if name == "." or name.startswith("."):
                continue
            if package["name"] == "linux-virt":
                if name == "boot/vmlinuz-virt":
                    offset, length = struct.unpack_from("<II", content, 8)
                    if offset + length > len(content) or content[offset:offset + 2] != b"\x1f\x8b":
                        raise ValueError("unexpected EFI zboot payload")
                    image = gzip.decompress(content[offset:offset + length])
                    if image[56:60] != b"ARM\x64":
                        raise ValueError("raw ARM64 Image magic is missing")
                elif name.endswith("/virtio_mmio.ko.gz"):
                    if not gzip.decompress(content).startswith(b"\x7fELF"):
                        raise ValueError("unexpected virtio_mmio module")
                    module = content
                continue
            if member.isdir():
                tree[name] = (stat.S_IFDIR | 0o755, b"", 0, 0)
            elif member.isfile():
                tree[name] = (stat.S_IFREG | (member.mode & 0o777), content, 0, 0)
            elif member.issym():
                tree[name] = (stat.S_IFLNK | 0o777, member.linkname.encode(), 0, 0)
            elif member.islnk():
                hardlinks[name] = safe_name(member.linkname)
            else:
                raise ValueError("unexpected special file in APK: " + name)
    for name, target in hardlinks.items():
        tree[name] = tree[target]
    if image is None or module is None:
        raise ValueError("kernel Image or virtio_mmio module not found")
    tree["lib/modules/virtio_mmio.ko.gz"] = (stat.S_IFREG | 0o644, module, 0, 0)
    for directory in ("bin", "sbin", "usr/bin", "usr/sbin", "etc", "dev", "proc", "sys",
                      "tmp", "run", "opt/habibi", "workspace", "workspace/home", "workspace/kit"):
        tree[directory] = (stat.S_IFDIR | (0o1777 if directory == "tmp" else 0o755), b"",
                           1000 if directory.startswith("workspace/") else 0,
                           1000 if directory.startswith("workspace/") else 0)
    for applet in ("sh", "mount", "mkdir", "mknod", "chmod", "chown", "insmod", "stty",
                   "sleep", "cat", "uname", "ls", "rm", "cp", "mv", "echo", "printf", "env",
                   "head", "tail", "wc", "sed", "grep", "find", "sort", "cut", "date", "touch",
                   "true", "false", "pwd", "id", "kill", "ps", "timeout", "xargs", "tee",
                   "ln", "basename", "dirname", "tr", "expr", "test", "readlink", "rmdir", "gzip"):
        tree["bin/" + applet] = (stat.S_IFLNK | 0o777, b"busybox.static", 0, 0)
    # Needed before devtmpfs is mounted, especially for PID1's initial stdio.
    tree["dev/console"] = (stat.S_IFCHR | 0o600, b"", 0, 0, 5, 1)
    tree["dev/null"] = (stat.S_IFCHR | 0o666, b"", 0, 0, 1, 3)
    tree["init"] = (stat.S_IFREG | 0o755, (HERE / "init").read_bytes(), 0, 0)
    tree["opt/habibi/rpc.py"] = (stat.S_IFREG | 0o644, (HERE / "rpc.py").read_bytes(), 0, 0)
    files = {"etc/passwd": "root:x:0:0:root:/:/bin/sh\nkit:x:1000:1000:kit:/workspace/home:/bin/sh\n",
             "etc/group": "root:x:0:\nkit:x:1000:\n",
             "etc/alpine-release": "3.22\n",
             "etc/os-release": 'NAME="Alpine Linux"\nID=alpine\nVERSION_ID=3.22\n',
             "etc/hosts": "127.0.0.1 localhost\n::1 localhost\n"}
    for name, value in files.items():
        tree[name] = (stat.S_IFREG | 0o644, value.encode(), 0, 0)
    for name in list(tree):
        for parent in PurePosixPath(name).parents:
            if str(parent) != ".":
                tree.setdefault(str(parent), (stat.S_IFDIR | 0o755, b"", 0, 0))
    # No setuid/setgid executables or host filesystem shares in this image.
    return image, tree


def newc(tree):
    result = io.BytesIO()
    for inode, (name, entry) in enumerate(sorted(tree.items()) + [("TRAILER!!!", (0, b"", 0, 0))], 1):
        mode, data, uid, gid = entry[:4]
        major, minor = entry[4:] if len(entry) == 6 else (0, 0)
        encoded = name.encode() + b"\0"
        fields = (inode, mode, uid, gid, 2 if stat.S_ISDIR(mode) else 1, EPOCH,
                  len(data), 0, 0, major, minor, len(encoded), 0)
        result.write(b"070701" + b"".join(("%08x" % field).encode() for field in fields))
        result.write(encoded)
        result.write(b"\0" * (-result.tell() % 4))
        result.write(data)
        result.write(b"\0" * (-len(data) % 4))
    result.write(b"\0" * (-result.tell() % 512))
    return result.getvalue()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--update-lock", action="store_true", help="explicitly resolve official APKINDEX and repin checksums")
    args = parser.parse_args()
    import subprocess
    if subprocess.run(["git", "check-ignore", "--quiet", ".amp/in/tinyarm-sim/guest-build/probe"], cwd=REPO).returncode != 0:
        raise ValueError("first add /.amp/in/ to the repository-local git info/exclude")
    downloads = BUILD / "downloads"
    downloads.mkdir(parents=True, exist_ok=True)
    lock = resolve_lock(downloads) if args.update_lock else json.loads((HERE / "apk-lock.json").read_text())
    if lock["roots"] != ROOTS or lock["kernel"] != KERNEL or lock["architecture"] != "aarch64":
        raise ValueError("unexpected lock roots")
    image, tree = assemble(lock, downloads)
    PACK.mkdir(parents=True, exist_ok=True)
    (PACK / "bzImage").write_bytes(image)
    with (PACK / "initramfs.cpio.gz").open("wb") as output:
        with gzip.GzipFile(filename="", mode="wb", fileobj=output, mtime=EPOCH, compresslevel=9) as compressed:
            compressed.write(newc(tree))
    config = {"version": 1, "machine": "aarch64", "memory_size": 512,
              "consoles": 2, "ports": 0, "kernel": "bzImage", "initrd": "initramfs.cpio.gz",
              "cmdline": "console=hvc0 rdinit=/init panic=-1"}
    (PACK / "config").write_text(json.dumps(config, indent=2, sort_keys=True) + "\n")
    manifest = {"format": 1, "architecture": "aarch64", "alpine": "3.22",
                "kernel": KERNEL, "unauditedPrototype": True,
                "apkLockSha256": sha256((HERE / "apk-lock.json").read_bytes()),
                "files": {name: {"sha256": sha256((PACK / name).read_bytes()), "bytes": (PACK / name).stat().st_size}
                          for name in ("bzImage", "initramfs.cpio.gz", "config")}}
    (PACK / "guest-manifest.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    print(json.dumps({"pack": str(PACK), **manifest}, indent=2))


if __name__ == "__main__":
    main()
