// Research harness: executes inside Linux, never on the inference host.
// One checkpointed turn per invocation lets the native host broker inference
// without giving the VM a provider credential or a network interface.
import { spawnSync } from "node:child_process";
import { readFileSync, writeFileSync, renameSync } from "node:fs";

const path = "/workspace/home/coding-session.json";
const instructions = `You are coding inside an ARM64 Alpine Linux research guest.
Your only tool is exec: return {kind:"exec",argv:[...],stdin:"",reply:""}.
Commands run as uid1000 in /workspace/kit. Git, Node 22 (jitless), Ruby 3.4,
Elixir 1.18, mise, Python and sh are available; no npm, C compiler or credentials.
External network access requires explicit host grants through a loopback adapter.
Read the existing source and tests and follow the task's scope. Run the relevant
tests and inspect the Git diff. Do not commit unless the task requests it.
Use small commands, at most 8 tool turns, 45 seconds per command and 2KiB
combined output. Avoid Node subprocess test runners: use direct assertions.
When finished return {kind:"reply",argv:[],stdin:"",reply:"brief result"}.
A reply is not execution proof; the caller independently checks the result.`;

const require = (condition, message) => { if (!condition) throw new Error(message); };
const input = readFileSync(0, "utf8");
require(Buffer.byteLength(input) <= 16 * 1024, "Input exceeds 16KiB");
const request = JSON.parse(input);
let state;
if (typeof request.task === "string") {
  require(request.task.length > 0 && request.task.length <= 4096, "Invalid task");
  try { readFileSync(path); throw new Error("Session already exists"); }
  catch (error) { if (error.code !== "ENOENT") throw error; }
  state = { history: [{ role: "user", content: request.task }], turns: 0, done: false };
} else {
  state = JSON.parse(readFileSync(path, "utf8"));
  require(!state.done, "Session is already finished");
  const answer = request.answer;
  require(answer && ["exec", "reply"].includes(answer.kind), "Invalid answer kind");
  require(typeof answer.reply === "string" && answer.reply.length <= 4096, "Invalid reply");
  if (answer.kind === "reply") {
    state.done = true;
    state.history.push({ role: "assistant", content: answer.reply });
  } else {
    require(state.turns < 8, "Tool turn budget exhausted");
    require(Array.isArray(answer.argv) && answer.argv.length > 0 && answer.argv.length <= 32 &&
      answer.argv.every(arg => typeof arg === "string" && !arg.includes("\0")) &&
      answer.argv[0] && Buffer.byteLength(JSON.stringify(answer.argv)) <= 8192, "Invalid argv");
    require(typeof answer.stdin === "string" && Buffer.byteLength(answer.stdin) <= 8192, "Invalid stdin");
    const result = spawnSync(answer.argv[0], answer.argv.slice(1), {
      cwd: "/workspace/kit", input: answer.stdin, encoding: "utf8",
      timeout: 45000, killSignal: "SIGKILL", maxBuffer: 2048,
    });
    const stdout = (result.stdout ?? "").slice(0, 1024);
    const stderr = (result.stderr ?? "").slice(0, 1024);
    state.turns += 1;
    state.history.push({ role: "assistant", content: JSON.stringify(answer) });
    state.history.push({ role: "user", content: JSON.stringify({
      exitCode: result.status, signal: result.signal, stdout, stderr,
      error: result.error?.code ?? null,
      truncated: stdout !== result.stdout || stderr !== result.stderr,
    }) });
  }
}
const output = JSON.stringify({ instructions, ...state });
require(Buffer.byteLength(output) <= 24 * 1024, "Transcript budget exhausted");
writeFileSync(path + ".tmp", JSON.stringify(state), { mode: 0o600 });
renameSync(path + ".tmp", path);
process.stdout.write(output + "\n");
