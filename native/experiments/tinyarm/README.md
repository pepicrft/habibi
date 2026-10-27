# Native TinyARM Lab

An unshipped **iOS Simulator-only experiment**, separate from the production
Habibi app and its Wasm Kit runtime. Native TinyARM interprets ARM64 Linux;
the guest runs real Git, Python and shell. It does not compile a Kit to Wasm.
No workout implementation is preinstalled: the model writes, tests and commits
source through the simulator app's JSON `exec` interface.

There is also a separate [coding-agent pack](guest/README.md#coding-agent-pack)
with Node, Ruby, Elixir and mise, a guest-resident checkpointed Node harness,
host-brokered read-only Git access, byte/inode quotas, and optional request/body
and file-syscall recordings. Its command-line driver and policy broker run on
the Mac, using the iOS simulator library. A separate simulator coding app below
runs the driver and a narrower, fixed-repository Git broker inside the app.
Inference remains outside the VM; the model returns commands as data.

## Run locally

Requires Apple Silicon, an installed iOS simulator, Xcode, Node, Python3, an
authenticated Claude CLI and Zig 0.17 (`mise install zig@0.17.0`). Ensure the
repository-local Git exclude contains `/.amp/in/` before building. In one
terminal, from the repository root:

```sh
node native/experiments/tinyarm/bridge.mjs
```

Then, in another terminal:

```sh
bash native/experiments/tinyarm/build-simulator.sh
xcrun simctl install <simulator-id> .amp/in/tinyarm-sim/HabibiLab.app
xcrun simctl launch <simulator-id> fyi.habibi.tinyarmlab
```

Enable the disclosure toggle and request a workout tracker. Review committed
source before installing, enter sets using native controls, then run the Python
summary. This narrow prototype supports one installed Kit. It is not wired into
the production vault, sync, onboarding, extension registry or model harness.

### On-device repository coding demo

Start `node native/experiments/tinyarm/bridge.mjs --coding` in another terminal,
then build and install the separate app (the default Kit app is unchanged):

```sh
bash native/experiments/tinyarm/build-simulator.sh --coding-app
xcrun simctl install <simulator-id> .amp/in/tinyarm-sim/HabibiCodingLab.app
xcrun simctl launch <simulator-id> fyi.habibi.tinyarmcoding
```

Approve the source disclosure and tap **Pull project & work on it**. The app
boots the coding pack, shallow sparse-clones public `tuist/tuist`, runs the
standalone bin-packer ExUnit file, asks the remote model to add one negative-total
test through the guest Node harness, then independently reruns ExUnit and checks
that only the requested test changed and every original line remains. This is
**not the full Mix/server suite**, local model inference, or production Habibi.
There is no commit or push. The guest workspace is discarded on completion.

The app's URLSession broker permits only that repository's two read-only Git
upload-pack endpoints. It rejects other destinations, push and redirects; it
does not grant arbitrary package downloads or automatic mise installation.
It uses platform HTTPS validation, 64 attempts, 64 KiB requests, 8 MiB responses
and a 16 MiB session budget. Source/tool output goes to the remote model through
the Mac development inference bridge on loopback 8085; no guest command executes
on the Mac. This bridge is still required and is not a physical-device setup.

Actual command results, before/after counts and recorded Git request/response
bodies with SHA256s are saved under the app's Documents directory in a unique
`coding-<UUID>` directory. These logs contain public source. To automate a
simulator recording, launch with `--run-coding-demo`; this is an explicit opt-in
that bypasses the disclosure toggle/button and starts the same real workflow.
Use `xcrun simctl io <simulator-id> recordVideo --codec=h264 <output.mp4>` and
send that recorder SIGINT to finalize the video.

The development bridge listens on runner loopback port 8084, with a random local
bearer token embedded only in this simulator build. Restarting the bridge
requires rebuilding/reinstalling the app. Claude tools, hooks/settings safe-mode,
MCP, skills, browser integration and session persistence are disabled. Model
commands are returned as data and executed only by the guest, never the host.
Coding conversations go to the model provider and are saved locally for audit
under excluded scratch; use fictional information. Private installed-Kit inputs
and outputs have no inference path.

## Host contract and privacy boundary

`kit.json` declares version 1, name, description, typed native fields and an argv
entrypoint. Python is a prototype choice, not the ABI: an available shell or
other interpreter can consume the same JSON stdin and return JSON metrics.
The host owns field validation, native UI, installation approval and encrypted
persistence. See [guest RPC](guest/README.md) for exact wire shapes and limits.

Authoring uses one disposable VM with no private entries. Only a clean Git
revision's bounded, regular UTF-8 files can be exported. Installation seals that
source and later entries using AES-GCM with an independent device-only Keychain
key, in bundle `fyi.habibi.tinyarmlab`. Each private summary cold-boots another VM,
imports only reviewed source, passes only this Kit's entries, validates metrics,
then discards that VM. No model access resumes after private import. The real
Habibi vault is never opened.

This experiment has no schema upgrades. A production contract should distinguish
package version from storage schema version, require an explicit migration,
run it against only that Kit's old records in a fresh offline sandbox, validate
the entire replacement, and atomically seal it while retaining recovery state
outside the guest. Never execute arbitrary SQL against the shared vault or
replace stored records before validation. Publishing must export code/schema
only, never local entries, credentials, Git history containing secrets or VM RAM.

## What this does not make safe

The pinned TinyARM source is `bac69aa0253b10fce6a93b3d2eccf134911ed231`.
`tinyarm-no-host-fs.patch` removes **all three** 9p devices and corrects the device
tree count; stock native TinyARM exports the actual host root. Both packs have no
drives, NICs or snapshots. The coding pack has a loopback-only HTTP adapter whose
external requests require a host policy broker (the Mac driver or the separate
coding app's fixed-repository broker). A separate copy of Zig's stdlib
gets the small iOS process-replacement availability fix; the installed toolchain
is unchanged.

The C ABI is process-global and serialized. A dedicated 16 MiB native thread
avoids the observed default-stack crash. Guest limits bound command time,
output, child address space and temporary files; the host has boot/RPC deadlines
and a step allowance. Cancellation is **cooperative**, not an OS-enforced kill
boundary. Guest RAM (512 MiB for Kits, 1 GiB for coding) is not a bound on the
emulator's total allocation.
The output callback's queue is not a production-grade hostile-output limiter.

Removing devices closes intended filesystem/network routes, not emulator bugs.
A native emulator exploit shares the app's authority. There is no security audit,
seccomp policy, formal artifact attestation, hard host memory budget, physical
iPhone/Android compatibility result or App Store approval. The upstream core's
distribution license remains unresolved. Do not ship it or admit untrusted
public packages on the strength of this experiment.

Keep credentials and vault keys outside the entire guest. A future on-device
broker must grant repository/operation/destination/expiry-scoped actions, with
separate approval for publish/destructive operations. A credential helper that
returns a token to Git does not keep that token outside the guest; hidden tokens
also do not stop misuse of an authorized operation. A Habibi-operated plaintext
credential proxy would expand the server trust boundary. No such broker or
credential transport is implemented here; the coding broker handles only public,
explicitly granted resources without credentials.

## Checks

```sh
python3 -B native/experiments/tinyarm/guest/test_guest.py
python3 -B native/experiments/tinyarm/guest/smoke_native.py --device <simulator-id>
node --check native/experiments/tinyarm/bridge.mjs
bash -n native/experiments/tinyarm/build-simulator.sh
```

The native smoke boots real Linux through the compiled simulator library; it is
not an agent/UI end-to-end test. It covers real Git/commit/export, Python shared
libraries, long stdin, fresh private import, output truncation and guest timeout.
UI/model installation and persistence must also be exercised after changes to
the Swift host. Python startup and multi-process tests can be slow under full
CPU emulation; do not interpret a model's completion message as execution proof.
