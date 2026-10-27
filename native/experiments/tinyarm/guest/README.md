# TinyARM simulator guest (unaudited experiment)

This is real Alpine v3.22/aarch64 Linux, Python 3.12.15, Git 2.49.1 and
BusyBox `/bin/sh`, not a mocked command executor. No workout implementation is
preinstalled. The model creates its own files in the initially empty
`/workspace/kit`. This is a prototype, **not an audited hostile-code sandbox**.

## Prepare

From the repository root, with Python 3.9+, curl and Git (no root or Docker):

```sh
python3 -B native/experiments/tinyarm/guest/prepare.py
python3 -B native/experiments/tinyarm/guest/test_guest.py
```

The repository-local Git exclude must already contain `/.amp/in/`; the builder
checks before writing. Downloads stay in `.amp/in/tinyarm-sim/guest-build/downloads`.
The prepared pack is `.amp/in/tinyarm-sim/pack/`:

* `config`: TinyARM config, relative kernel/initrd paths, 512MiB, two consoles,
  zero multiports, no drives or NICs. Host arguments: `-net none -no-stdin -smp 1`.
* `bzImage`: **raw ARM64 Image**, despite this historical filename.
* `initramfs.cpio.gz`: complete runtime and custom `/init`, not stock `/pack/init`.
* `guest-manifest.json`: sizes and SHA256s, plus the APK lock hash.

`apk-lock.json` pins all 31 official APK URLs and SHA256s, including recursively
resolved shared-library providers. Default builds do not consult a moving APK
index. Explicit maintenance command `prepare.py --update-lock` resolves Alpine's
official v3.22 main/aarch64 APKINDEX again, failing ambiguous providers rather
than guessing. Pinned root versions must still be available. HTTPS and the
checked-in hashes are the trust anchors; this builder does **not** independently
verify Alpine APK signatures. Keep the download cache if upstream removes old
APKs. No package installation scripts run on the host or in the guest.

The kernel is `linux-virt-6.12.114-r0`. Its EFI zboot gzip offset/length are
little-endian u32s at bytes 8/12; the decompressed Image must have `ARM\x64`
at byte 56. Only its `virtio_mmio.ko.gz` is included; init decompresses and
insmods that exact module. `CONFIG_VIRTIO_CONSOLE=y`, `CONFIG_VIRTIO_MMIO=m`.
Archive ordering, ownership, mtimes and gzip header are deterministic.

## Native simulator smoke

Use the parent's no-9p TinyARM static library and an already booted simulator:

```sh
python3 -B native/experiments/tinyarm/guest/smoke_native.py \
  --device 38475EA4-941E-413F-9C52-45A3D16D1F02
```

`--runtime` optionally selects a directory with `include/tinyarm.h` and
`lib/libtinyarm.a`; default `.amp/in/tinyarm-sim/runtime-simulator`.
The script compiles `native_rpc_host.c` using the iOS simulator SDK and runs it
with `xcrun simctl spawn`. Binary and logs stay in `guest-build/`. It checks
Python shared libraries, uid/gid, 12KiB stdin, real shell/Git/commit/export,
dirty rejection, output truncation and timeout, then boots a **separate fresh
VM process** for import and a private-stdin transport fixture. The fixture is
`cat`, not workout code. Private content is never copied back to authoring RAM.

**Embedding requirement:** run `tinyarm_main` on a native thread with a large
stack. The harness uses 16MiB. A default iOS pthread's approximately 512KiB stack
overflows in upstream `main.run` before boot. A serial DispatchQueue alone does
not specify a sufficient stack size.

## Console handshake

Inspected pinned upstream `bac69aa0253b10fce6a93b3d2eccf134911ed231`:
`virtio_runtime.zig:190-194,1028-1055,1345-1368`. It recognizes **ten consecutive
`=` bytes on hvc0**, including across writes, suppresses that marker, then
automatically injects `=\n` on console0. Embedded console input does not drain
until that acknowledgement has been delivered. The host must **not** send an
extra acknowledgement. Init keeps hvc0 open across stty, marker write and read:
last-close can reset terminal settings or discard the acknowledgement. It also
keeps hvc1 open while setting **`raw -echo`**, then hands the same open descriptor
to Python, avoiding canonical-mode 4095-byte input loss and CRLF/echo corruption.

Channel1 starts with:

```json
{"event":"ready","protocol":1,"python":"3.12.15","git":"git version 2.49.1"}
```

Host callbacks contain arbitrary byte fragments, not complete lines. Buffer
until LF. Retry the unaccepted suffix of `tinyarm_console_input` (console queues
are 256KiB). Serialize requests; keep boot/lifecycle/output deadlines on host.

## RPC v1

Every valid request has a UUID string `id`; every response echoes it and has
boolean `ok`. Malformed JSON or missing/non-string ids use `id:null`. Request
lines are bounded to 1MiB including LF. Examples use an illustrative UUID:

```json
{"id":"11111111-1111-4111-8111-111111111111","op":"exec","argv":["sh","-c","pwd; git --version"],"timeoutMs":20000,"stdin":""}
```

`exec` returns `{id,ok:true,exitCode,stdout,stderr,truncated}`. `timeoutMs` is an
integer 1..20000; stdin is optional and at most 128KiB UTF-8. Combined stdout and
stderr are at most 32KiB UTF-8 (invalid output is replaced and bounded again).
Wall timeout is exit124; signals map to 128+signal. Output continues draining
after truncation. Child output never writes the response terminal directly.

Children run uid/gid1000, no supplementary groups, cwd `/workspace/kit`,
HOME `/workspace/home`, PATH `/usr/bin:/bin`, with a small constructed environment,
never host environment/credentials. Limits: CPU ceil(timeout seconds) soft and
one second more hard, 192MiB address space, 8MiB file size, 64 descriptors,
32 uid processes, zero core dump, `PR_SET_NO_NEW_PRIVS`. Cleanup kills the child
process group and scans/reaps all uid1000 processes, including detached sessions.
The root service/Python code and console devices are not writable by uid1000.
The guest mounts 64MiB workspace and 32MiB temp tmpfs with nosuid,nodev.

The workspace also has a 4096-inode cap; temp has 2048. Both are disposable
guest filesystems, not host directories. Byte and inode exhaustion return
`ENOSPC`. Neither mount grants access to the app's documents or vault.
Trusted init disables user namespaces before starting RPC, preventing uid1000
from mounting another tmpfs outside these budgets. Both native pack smokes
check that `unshare(CLONE_NEWUSER)` is denied for uid1000.

`export`: `{id,op:"export"}` returns **`{id,ok:true,artifact:{revision,files}}`**.
`files` is `[{path,content}]`, UTF-8 strings; revision is a 40-character lowercase
Git SHA. A dropped-privilege worker runs all Git checks and file reads. It requires
a standalone committed repository at kit root, clean including ignored/untracked
files. Only tracked regular files whose exact bytes match committed Git blobs
are accepted. Symlinks, hardlinks, submodules, `.git` components, absolute,
traversing and control-character paths are rejected. Bounds: 128 files, 32KiB
each, 128KiB combined content. `kit.json` is mandatory.

`import`: **`{id,op:"import",artifact:{revision,files}}`** returns `{id,ok:true}`.
It validates the same artifact and creates fresh uid1000 regular files, no Git
metadata. It is permitted only before any exec/export and once per boot. It is
**only for a fresh private VM**, never an authoring VM reused by the model.
The guest cannot authenticate callers: the host must ensure the agent never
gets that VM's stdin, output or later access. Do not persist or reuse its RAM.

Errors are `{id,ok:false,error:string}`. Import file modes are 0644, so invoke
scripts via their interpreter rather than relying on executable bits.

`kit.json`: `{apiVersion:1,name,description,fields:[{key,label,type,min?,max?,unit?}],entrypoint:[...]}`.
Types are `string`, `number`, **`integer`**. Entrypoint is an argv array, not a
shell string; Python and `sh` entrypoints both work. No language-specific workout
logic exists in the guest. Runtime kit input is one JSON document
`{apiVersion:1,operation:"summarize",entries:[...],today:"YYYY-MM-DD"}` and the kit
must return `{metrics:[{label,value:string}]}` on stdout. Validation/execution of
that application-level output is the host's responsibility.

## Limits and additional tests

On an ordinary **dedicated disposable Linux VM**, as root with Git/Python/sh:

```sh
HABIBI_DISPOSABLE_RPC_TEST=1 python3 -B native/experiments/tinyarm/guest/test_rpc_linux.py
```

This tests the public JSONL subprocess interface without emulator boot. It
refuses pre-existing uid1000 tasks because service cleanup intentionally kills
all such tasks. Never run the service or this opt-in test on a normal Linux
desktop/server. Portable `test_guest.py` tests pipe draining and archive/ELF
dependency completeness but does not by itself prove a Linux boot.

No seccomp policy, formal export attestation, audited kernel/emulator isolation
or complete denial-of-service prevention is claimed. A hostile command can read
guest-public files and consume guest resources. Git configuration/filters may
execute code, but only as uid1000, never root. Guest deadlines and cleanup do not
replace host hard lifecycle termination. No credential capability exists here.

## Coding-agent pack

This separate pack adds Node 22.23.4, Ruby 3.4.4/Bundler 2.6.8, Elixir 1.18.3
on Erlang/OTP 27, mise 2025.5.10, PostgreSQL 17.11 and strace. Versions and
transitive APK URLs/hashes live in `coding-apk-lock.json`, including Alpine's
community repository. The default Kit pack and simulator app do not get these
tools, the harness or a network adapter.

```sh
bash native/experiments/tinyarm/build-simulator.sh --coding
python3 -B native/experiments/tinyarm/guest/test_guest.py --coding
python3 -B native/experiments/tinyarm/guest/coding_smoke.py \
  --device <simulator-id> --network --record
```

The last command uses deterministic fixture inference, not a real model. For
live inference start `node native/experiments/tinyarm/bridge.mjs --coding` and
add `--model` to the smoke command. This discloses the task, source and command
results to the provider. The bridge uses runner loopback port 8085 and a
host-only random bearer token. No provider credentials enter Linux. The
checkpointed harness itself executes **inside guest Node**, not on the Mac;
this is a small experimental harness, not Amp/Pi or local model inference.

Coding output is `.amp/in/tinyarm-sim/coding-pack`, with 1GiB guest RAM and
three consoles. The larger initramfs did not boot in the 512MiB configuration.
Coding-pack drivers allow 300 seconds for cold boot; the default Kit smoke
retains 120 seconds. This does not extend guest command deadlines.
Coding commands have a 120-second maximum, 8GiB *virtual address-space* ceiling,
64MiB file-size ceiling and 128 descriptors; the original Kit limits remain
unchanged. BEAM's JIT creates a 64MiB memfd even for `elixir --version`, so an
8MiB file ceiling killed it with `SIGXFSZ`. Workspace/temp quotas still apply.
Node uses `--jitless --max-old-space-size=64`; BEAM uses one scheduler and small
worker pools. Neither guest RAM nor address-space limits bound total host memory.

### Host-brokered networking and recordings

There is still **no guest NIC or host filesystem share**. Root owns a guest
loopback HTTP adapter and console2. Agent Git uses, for example,
`http://127.0.0.1:8080/https/github.com/octocat/Hello-World.git`. The Mac policy
broker makes the corresponding HTTPS request; it is not a transparent TCP/TLS
proxy and has not been ported to Swift/iPhone.

Default deny. A grant approves only exact repository `info/refs` GETs for
`git-upload-pack` and `git-upload-pack` POSTs, never push. Downloads require an
exact URL and SHA256. Requests cannot supply credentials, cookies or arbitrary
headers. Redirects and non-public/multicast DNS answers are rejected; the broker
connects to the checked IP and validates TLS for the original hostname. Limits:
64 attempts including denials, 64KiB request bodies, 8MiB responses, 16MiB session
response bytes. DNS itself is not hard-deadline bounded. This is an unaudited
application policy, not proof against kernel/emulator escapes or all DoS.

`--record` writes owner-only raw approved request/response bodies plus status,
content type, byte counts and SHA256s. Denials record metadata, not a complete
packet capture. Records may contain source or page content. `traceFiles:true`
wraps an RPC command and descendants in root-owned `strace -f -u kit -e
trace=%file`; the command still runs uid1000. Its response adds `fileTrace` and
`fileTraceTruncated`, bounded to 256KiB. The temporary root-only trace file has
the coding 64MiB file limit and is removed after collection. These are path/open/
rename/unlink syscall traces, **not every read/write byte or a tamper-proof
filesystem audit**. The smoke independently checks recordings, denied egress,
read-only cloning, pinned downloads and byte/inode exhaustion.

### Real repository and database trials

```sh
python3 -B native/experiments/tinyarm/guest/tuist_smoke.py --device <simulator-id>
python3 -B native/experiments/tinyarm/guest/postgres_smoke.py --device <simulator-id>
```

The Tuist trial needs the coding inference bridge. It shallow/sparse-clones the
real public `tuist/tuist`, asks the model to add one negative-total regression
test to the server's `Tuist.Shards.BinPackerTest`, and independently checks the
diff, preserved tests and one additional passing test. It runs the real module
and test with standalone ExUnit, **not the server Mix test helper, application,
database suite or full repository checkout**. It separately attempts `mix test`.
Tuist requires Elixir `~> 1.19`, newer than this pack; dependencies, native
compilers and external services are not provisioned. Its tracked server tree
alone is about 135MiB, beyond this 64MiB workspace. Do not report this focused
trial as the full Tuist development environment running on an iPhone.

The Postgres trial initializes a disposable cluster, runs SQL and rollback
checks, restarts it and rechecks the rows, then deletes the data. It uses a
guest-only Unix socket, 1MiB WAL segments, 8MiB shared buffers, five connections
and mmap dynamic shared memory. `--no-sync`/`-F` deliberately disable durability
for scratch tests. Server/client run within one RPC command because cleanup
kills uid1000 daemons between commands. There is no persistent database service
manager, host database access or durable disk implemented.

Results and logs are in `guest-build/{coding-fixture,coding-model,tuist,postgres}-result.json`
and adjacent logs/recording directories. Inspect `passed` and each command's exit
code; a model completion message alone does not establish success.

### Tool compatibility is not yet a full workstation

Mise itself runs, but tool installation through its multiple registries,
redirects, archives and build backends is not implemented by these narrow
network grants. Nix is not installed/tested: it needs a writable, separately
budgeted store (normally `/nix`) and a compatible build/sandbox configuration.
Do not silently grant unrestricted networking to make either installer work.

Lightpanda is not installed: its official Linux ARM64 binary requires glibc,
whereas this guest is musl. A glibc browser pack or source port and CDP request
interception through the same broker are separate work. It is not Chromium's
visual rendering engine. Disable its telemetry before any trial.

Current [ClickHouse ARM64 images](https://github.com/ClickHouse/ClickHouse/blob/master/docker/server/README.src/content.md)
require ARMv8.2-A plus RCpc/`LDAPR`. The pinned TinyARM's
`aarch64_cpu.zig:execAtomicMemory` explicitly rejects `LDAPR`; stock current
ClickHouse is therefore not a supported candidate for this interpreter. It
also needs substantially different storage, memory, descriptor and worker
budgets. No ClickHouse process has been tested here.

Alternatives worth evaluating are [UTM SE](https://getutm.app/) (QEMU-based
full-system interpretation on iOS without JIT), [iSH](https://ish.app/) (x86
user-mode emulation/syscall translation, not a full Linux kernel), and
[a-Shell](https://github.com/holzschu/a-shell) (native ports with process/API
limitations). macOS hardware virtualization does not imply that ordinary iOS
apps can use it. No alternative or physical iPhone has been validated by this
prototype; interpreter performance and App Store/licensing feasibility remain
separate questions.
