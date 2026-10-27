#if CODING_LAB
import CryptoKit
import SwiftUI

private final class NoRepositoryRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

// Deliberately narrower than the Mac research broker: one public GitHub repo,
// upload-pack only, no credentials, downloads, redirects, or arbitrary hosts.
// This broker runs in the simulator app, not in a Mac subprocess.
private actor RepositoryNetwork {
    private let repository = "https://github.com/tuist/tuist.git"
    private let directory: URL
    private let session: URLSession
    private var attempts = 0
    private var received = 0

    init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 45
        session = URLSession(configuration: config, delegate: NoRepositoryRedirects(), delegateQueue: nil)
    }

    func handle(_ request: [String: Any]) async -> [String: Any] {
        attempts += 1
        let number = attempts
        do {
            guard number <= 64, let url = request["url"] as? String,
                  let method = request["method"] as? String,
                  (method == "GET" && url == repository + "/info/refs?service=git-upload-pack") ||
                  (method == "POST" && url == repository + "/git-upload-pack"),
                  let body = Data(base64Encoded: request["body"] as? String ?? ""),
                  body.count <= 64 * 1024, method != "GET" || body.isEmpty,
                  received < 16 * 1024 * 1024 else {
                throw LabFailure(message: "Only the approved public tuist/tuist read-only Git endpoints are allowed.")
            }
            var outgoing = URLRequest(url: URL(string: url)!)
            outgoing.httpMethod = method
            outgoing.httpBody = body.isEmpty ? nil : body
            outgoing.setValue("Habibi-TinyARM-Lab", forHTTPHeaderField: "User-Agent")
            outgoing.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
            if request["gitProtocol"] as? String == "version=2" {
                outgoing.setValue("version=2", forHTTPHeaderField: "Git-Protocol")
            }
            if method == "POST" {
                outgoing.setValue("application/x-git-upload-pack-request", forHTTPHeaderField: "Content-Type")
            }
            let (stream, response) = try await session.bytes(for: outgoing)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw LabFailure(message: "GitHub rejected the request; redirects are not followed.")
            }
            let limit = min(8 * 1024 * 1024, 16 * 1024 * 1024 - received)
            guard response.expectedContentLength <= limit else {
                throw LabFailure(message: "Repository response exceeds the network budget.")
            }
            var data = Data()
            for try await byte in stream {
                received += 1
                guard data.count < limit else {
                    throw LabFailure(message: "Repository response exceeds the network budget.")
                }
                data.append(byte)
            }
            let name = String(format: "%02d", number)
            try body.write(to: directory.appendingPathComponent(name + "-request.bin"), options: .atomic)
            try data.write(to: directory.appendingPathComponent(name + "-response.bin"), options: .atomic)
            let audit: [String: Any] = ["url": url, "method": method, "status": 200,
                "requestBytes": body.count, "responseBytes": data.count,
                "sha256": SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()]
            try JSONSerialization.data(withJSONObject: audit, options: [.prettyPrinted, .sortedKeys])
                .write(to: directory.appendingPathComponent(name + ".json"), options: .atomic)
            return ["ok": true, "contentType": http.value(forHTTPHeaderField: "Content-Type") ?? "application/octet-stream",
                    "body": data.base64EncodedString()]
        } catch {
            return ["ok": false, "error": error.localizedDescription]
        }
    }
}

@MainActor private final class CodingModel: ObservableObject {
    @Published var messages: [LabMessage] = []
    @Published var status = "Ready to pull tuist/tuist"
    @Published var busy = false
    @Published var consent = false
    @Published var passed = false
    @Published var error: String?
    @Published var started: Date?
    private let machine = NativeMachine()
    private var task: Task<Void, Never>?
    private var steps: [[String: Any]] = []
    private var directory: URL!
    private let source = "server/lib/tuist/shards/bin_packer.ex"
    private let test = "server/test/tuist/shards/bin_packer_test.exs"

    private var testCommand: [String] {
        ["elixir", "-r", source, "-e", "ExUnit.start(); Code.require_file(System.argv() |> hd())", test]
    }

    func start() {
        guard !busy, started == nil, consent else { return }
        busy = true
        started = Date()
        task = Task {
            defer { busy = false }
            do {
                directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("coding-" + UUID().uuidString)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let broker = try RepositoryNetwork(directory: directory.appendingPathComponent("network"))
                status = "Booting ARM64 Linux in this app…"
                note("Runtime", "1 GiB guest RAM · 64 MiB workspace\nNo host filesystem or guest NIC. Inference is remote.")
                _ = try await machine.start(bootTimeout: 300, network: { await broker.handle($0) })
                _ = try await execute(["sh", "-c", "uname -sm; id; git --version; node --version; elixir --version"], title: "Guest tools")

                let denied = """
                import urllib.request, urllib.error
                for path,method in (('github.com/other/repo.git/info/refs?service=git-upload-pack','GET'),
                                    ('github.com/tuist/tuist.git/git-receive-pack','POST'), ('127.0.0.1/private','GET')):
                    try:
                        urllib.request.urlopen(urllib.request.Request('http://127.0.0.1:8080/https/'+path,method=method))
                        raise AssertionError('unapproved network access')
                    except urllib.error.HTTPError as e:
                        assert e.code == 403
                print('Other repositories, push and localhost: denied')
                """
                _ = try await execute(["python3", "-c", denied], title: "Check app-side network policy")
                status = "Pulling tuist/tuist inside Linux…"
                _ = try await execute(["git", "-c", "core.hooksPath=/dev/null", "clone", "--quiet", "--depth=1",
                    "--filter=blob:none", "--no-checkout", "--single-branch",
                    "http://127.0.0.1:8080/https/github.com/tuist/tuist.git", "."], title: "Clone public repository")
                _ = try await execute(["git", "sparse-checkout", "set", "--no-cone", "/" + source, "/" + test], title: "Select server source and test")
                _ = try await execute(["git", "checkout", "--quiet", "HEAD"], title: "Check out source")
                let revision = try await execute(["git", "rev-parse", "HEAD"], title: "Pulled revision")
                status = "Running existing Elixir tests…"
                let before = try await execute(testCommand, title: "Before: standalone ExUnit")
                let original = try await execute(["cat", test], title: "Read original test file", display: false)
                let request = """
                In this real shallow sparse clone of tuist/tuist, change only \(test).
                Add one regression test: total: -3 clamps to one shard for two units
                with durations 13 and 7. Preserve all existing lines and the implementation.
                Read \(source) and relevant test context first, then edit the test file.
                Do not commit, push, or access the network. You have the harness's eight tool turns.
                Each tool's stdout is clipped at 1024 bytes: keep reads below 900 bytes.
                Use targeted Python reads around determine_shard_count and the total: tests;
                avoid whole-file dumps and shell pipelines that exhaust the output budget.
                Do not run Elixir within your 45s tool window: the native app independently
                runs the entire standalone test file before and after with a 120s allowance.
                Inspect git diff, then reply. This is standalone ExUnit, not the full Mix suite.
                """
                var state = try await turn(["task": request])
                for _ in 0..<9 {
                    status = "Remote model is choosing a guest command…"
                    let answer = try await infer(state)
                    if let argv = answer["argv"] as? [String], answer["kind"] as? String == "exec" {
                        note("Agent → Linux", argv.joined(separator: " "))
                        status = "Guest Node harness is executing the edit…"
                    }
                    state = try await turn(["answer": answer])
                    if let history = state["history"] as? [[String: Any]],
                       let last = history.last?["content"] as? String {
                        note(state["done"] as? Bool == true ? "Agent reply (not proof)" : "Guest tool result", last)
                    }
                    if state["done"] as? Bool == true { break }
                }
                guard state["done"] as? Bool == true else { throw LabFailure(message: "Agent exceeded its turn budget.") }
                status = "Independently checking the agent’s work…"
                let after = try await execute(testCommand, title: "After: standalone ExUnit")
                let verify = """
                import json,pathlib,subprocess,sys
                p=\(String(reflecting: test)); old=json.load(sys.stdin); new=pathlib.Path(p).read_text()
                assert subprocess.check_output(['git','diff','--name-only'],text=True).splitlines()==[p]
                lines=iter(new.splitlines())
                assert all(any(line==candidate for candidate in lines) for line in old.splitlines())
                assert 'total: -3' in new
                assert subprocess.check_output(['git','ls-files','--others','--exclude-standard'],text=True)==''
                print('Only requested test changed; every original line preserved; no untracked files')
                """
                _ = try await execute(["python3", "-c", verify], stdin: String(data: try JSONSerialization.data(withJSONObject: original, options: .fragmentsAllowed), encoding: .utf8)!, title: "Verify scope and preserve existing tests")
                guard let beforeCount = countTests(before), let afterCount = countTests(after), afterCount == beforeCount + 1 else {
                    throw LabFailure(message: "Expected exactly one additional passing ExUnit test.")
                }
                _ = try await execute(["git", "diff", "--", test], title: "Actual guest Git diff")
                try JSONSerialization.data(withJSONObject: ["passed": true, "physicalDevice": false,
                    "fullMixSuite": false, "remoteInference": true, "revision": revision,
                    "beforeTests": beforeCount, "afterTests": afterCount, "session": state, "steps": steps], options: [.prettyPrinted, .sortedKeys])
                    .write(to: directory.appendingPathComponent("result.json"), options: .atomic)
                await machine.stop()
                passed = true
                status = "Verified: \(beforeCount) → \(afterCount) tests, 0 failures"
                note("Verified locally", "Real clone, model edit and ExUnit ran inside the simulator app.\nStandalone test file only; not the full Mix suite.\nGuest discarded; no commit or push.")
            } catch {
                self.error = error.localizedDescription
                status = "Stopped without claiming success"
                note("Error", error.localizedDescription)
                if let directory {
                    try? JSONSerialization.data(withJSONObject: ["passed": false, "error": error.localizedDescription, "steps": steps], options: [.prettyPrinted, .sortedKeys])
                        .write(to: directory.appendingPathComponent("result.json"), options: .atomic)
                }
                await machine.stop()
            }
        }
    }

    private func countTests(_ text: String) -> Int? {
        let regex = try! NSRegularExpression(pattern: "(?m)^([0-9]+) tests?, 0 failures?\\b")
        guard let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return Int(text[range])
    }

    private func execute(_ argv: [String], stdin: String = "", title: String, display: Bool = true) async throws -> String {
        try Task.checkCancellation()
        if display { note(title, "$ " + argv.joined(separator: " ")) }
        let result = try await machine.request(["op": "exec", "argv": argv, "stdin": stdin, "timeoutMs": 120000], timeout: 150)
        steps.append(["argv": argv, "result": result, "time": ISO8601DateFormatter().string(from: Date())])
        try JSONSerialization.data(withJSONObject: steps, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("steps.json"), options: .atomic)
        let stdout = result["stdout"] as? String ?? ""
        let stderr = result["stderr"] as? String ?? ""
        if display { note(title + " · exit \(result["exitCode"] ?? "?")", stdout + stderr) }
        guard result["exitCode"] as? Int == 0, result["truncated"] as? Bool == false else {
            throw LabFailure(message: "\(title) failed: \(stdout)\(stderr)")
        }
        return stdout
    }

    private func turn(_ body: [String: Any]) async throws -> [String: Any] {
        let input = try JSONSerialization.data(withJSONObject: body)
        let output = try await execute(["node", "/opt/habibi/coding-harness.mjs"], stdin: String(decoding: input, as: UTF8.self), title: "Guest Node harness", display: false)
        guard let state = try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any] else {
            throw LabFailure(message: "Invalid guest harness state.")
        }
        return state
    }

    private func infer(_ state: [String: Any]) async throws -> [String: Any] {
        guard let file = Bundle.main.url(forResource: "bridge", withExtension: "json"),
              let config = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: String],
              let token = config["token"] else { throw LabFailure(message: "Missing simulator inference configuration.") }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:8085/step")!, timeoutInterval: 110)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["instructions": state["instructions"] as Any, "history": state["history"] as Any])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 128 * 1024,
              let answer = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LabFailure(message: "Remote inference failed; no model commands ran on the Mac.")
        }
        return answer
    }

    private func note(_ title: String, _ text: String) {
        messages.append(LabMessage(role: title, text: text))
        print("CODING: \(title)\n\(text)")
    }

    func cancel() { task?.cancel(); machine.interrupt() }
}

struct CodingView: View {
    @StateObject private var model = CodingModel()
    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    Label("tuist/tuist", systemImage: "chevron.left.forwardslash.chevron.right").font(.title2.bold())
                    Text("Git · Node harness · Elixir in ARM64 Linux").font(.subheadline)
                    Text("On-device execution · remote model inference").font(.caption).foregroundStyle(.secondary)
                    Divider()
                    HStack(alignment: .top) {
                        if model.busy { ProgressView().controlSize(.small) }
                        Text(model.status).font(.subheadline.weight(.semibold)).accessibilityIdentifier("Coding status")
                        Spacer(minLength: 4)
                        if let started = model.started, model.busy { Text(started, style: .timer).font(.caption.monospacedDigit()) }
                    }
                }.padding(.horizontal, 20)
                if model.started == nil {
                    VStack(alignment: .leading, spacing: 20) {
                        Text("Pull the real server source, add a negative-total regression test, then independently run the test file and check the diff.")
                            .fixedSize(horizontal: false, vertical: true)
                        Toggle("Allow public source and tool results to go to the development model", isOn: $model.consent).font(.subheadline)
                        Text("Read-only access to this public repository. 64 MiB disposable workspace. No host files or private data. Standalone ExUnit, not the full Mix suite.").font(.caption).foregroundStyle(.secondary)
                        Button("Pull project & work on it") { model.start() }.buttonStyle(.borderedProminent).disabled(!model.consent)
                    }.fixedSize(horizontal: false, vertical: true).padding(20)
                }
                ScrollViewReader { reader in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(model.messages) { message in
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(message.role).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                    Text(message.text.isEmpty ? "(no output)" : String(message.text.prefix(1800)))
                                        .font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                                }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
                                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
                            }
                            Color.clear.frame(height: 1).id("latest")
                        }.padding(.horizontal, 20)
                    }.onChange(of: model.messages.count) { _, _ in withAnimation { reader.scrollTo("latest", anchor: .bottom) } }
                }
                if let error = model.error { Text(error).font(.caption).foregroundStyle(.red).padding(.horizontal, 20) }
                Text(model.passed ? "Verified locally · no commit or push · VM discarded" : "Research prototype · iPhone Simulator · not production Habibi")
                    .font(.caption2).foregroundStyle(.secondary).padding(.horizontal, 20).padding(.bottom, 12)
            }.padding(.top, 12)
                .navigationTitle("Habibi Coding Lab").navigationBarTitleDisplayMode(.inline)
                .toolbar { if model.busy { Button("Stop", role: .destructive) { model.cancel() } } }
                .task {
                    // Explicit simulator automation opt-in; the normal launch
                    // always requires the visible disclosure toggle and button.
                    if ProcessInfo.processInfo.arguments.contains("--run-coding-demo") {
                        try? await Task.sleep(for: .seconds(3))
                        model.consent = true
                        model.start()
                    }
                }
        }.preferredColorScheme(.light)
    }
}
#endif
