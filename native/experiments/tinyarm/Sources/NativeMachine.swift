import Foundation
import TinyARM

struct LabFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

// The upstream ABI is process-global: one machine, serialized requests. This
// prototype has no 9p devices, drives, NICs, snapshots, or host tool execution.
final class NativeMachine: @unchecked Sendable {
    private let lock = NSLock()
    private let outputQueue = DispatchQueue(label: "habibi.lab.console")
    private var output = Data()
    private var ready: CheckedContinuation<[String: Any], Error>?
    private var pending: (String, CheckedContinuation<[String: Any], Error>)?
    private var running = false
    private var stopping = false
    private var generation = UUID()
    private var finished: CheckedContinuation<Void, Never>?

    func start() async throws -> [String: Any] {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            guard !running else {
                lock.unlock()
                continuation.resume(throwing: LabFailure(message: "A Linux machine is already running."))
                return
            }
            let run = UUID()
            generation = run
            running = true
            stopping = false
            ready = continuation
            lock.unlock()
            outputQueue.sync { output.removeAll(keepingCapacity: true) }
            let worker = Thread { [self] in
                let context = Unmanaged.passUnretained(self).toOpaque()
                tinyarm_set_console_output({ context, channel, bytes, length in
                    guard channel == 1, let context, let bytes, length > 0 else { return }
                    let machine = Unmanaged<NativeMachine>.fromOpaque(context).takeUnretainedValue()
                    let data = Data(bytes: bytes, count: length)
                    machine.outputQueue.async { machine.receive(data) }
                }, context)
                guard let config = Bundle.main.url(forResource: "config", withExtension: nil, subdirectory: "pack") else {
                    end(status: 1, message: "The offline Linux pack is missing.")
                    return
                }
                let argv = ["tinyarm", "-config", config.path, "-net", "none", "-no-stdin", "-smp", "1", "-host-qos", "initiated"]
                let pointers = argv.map { strdup($0)! }
                defer { pointers.forEach { free($0) } }
                var args: [UnsafePointer<CChar>?] = pointers.map { UnsafePointer<CChar>($0) } + [nil]
                let limit = strdup("TINYARM_MAX_STEPS=100000000000")!
                defer { free(limit) }
                var environment: [UnsafePointer<CChar>?] = [UnsafePointer(limit), nil]
                let argumentCount = Int32(pointers.count)
                let status = args.withUnsafeMutableBufferPointer { argv in
                    environment.withUnsafeMutableBufferPointer { env in
                        tinyarm_main(argumentCount, argv.baseAddress, env.baseAddress)
                    }
                }
                end(status: status, message: "Linux stopped (status \(status)).")
            }
            // Upstream main.run overflows the default iOS dispatch-thread stack.
            worker.stackSize = 16 * 1024 * 1024
            worker.qualityOfService = .userInitiated
            worker.name = "Habibi Linux"
            worker.start()
            DispatchQueue.global().asyncAfter(deadline: .now() + 120) { [weak self] in
                guard let self else { return }
                lock.lock()
                let overdue = generation == run && ready != nil
                lock.unlock()
                if overdue { fail("Linux did not become ready within two minutes.") }
            }
        }
    }

    func request(_ body: [String: Any], timeout: TimeInterval = 30) async throws -> [String: Any] {
        let id = UUID().uuidString
        var request = body
        request["id"] = id
        var bytes = try JSONSerialization.data(withJSONObject: request, options: [.sortedKeys])
        guard bytes.count <= 256 * 1024 else { throw LabFailure(message: "The guest request is too large.") }
        bytes.append(10)
        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            guard running, !stopping, ready == nil, pending == nil else {
                lock.unlock()
                continuation.resume(throwing: LabFailure(message: "Linux is not ready for another request."))
                return
            }
            pending = (id, continuation)
            lock.unlock()
            DispatchQueue.global().async { [self] in
                var offset = 0
                while offset < bytes.count {
                    lock.lock()
                    let active = pending?.0 == id && !stopping
                    lock.unlock()
                    if !active { break }
                    let sent = bytes.withUnsafeBytes { pointer in
                        tinyarm_console_input(1, pointer.baseAddress!.assumingMemoryBound(to: UInt8.self).advanced(by: offset), bytes.count - offset)
                    }
                    offset += sent
                    if sent == 0 { Thread.sleep(forTimeInterval: 0.005) }
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard let self else { return }
                lock.lock()
                let overdue = pending?.0 == id
                lock.unlock()
                if overdue { fail("The guest request timed out; this machine was stopped.") }
            }
        }
    }

    func stop() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            guard running else { lock.unlock(); continuation.resume(); return }
            guard finished == nil else { lock.unlock(); continuation.resume(); return }
            finished = continuation
            stopping = true
            let boot = ready
            let call = pending?.1
            ready = nil
            pending = nil
            lock.unlock()
            boot?.resume(throwing: LabFailure(message: "Linux stopped."))
            call?.resume(throwing: LabFailure(message: "Linux stopped."))
            tinyarm_request_stop()
        }
    }

    func interrupt() { fail("Cancelled. The Linux workspace will be discarded.") }

    private func receive(_ data: Data) {
        output.append(data)
        guard output.count <= 512 * 1024 else { fail("The guest exceeded its output budget."); output.removeAll(); return }
        while let newline = output.firstIndex(of: 10) {
            let line = output.prefix(upTo: newline)
            output.removeSubrange(...newline)
            guard let value = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            lock.lock()
            if value["event"] as? String == "ready", let boot = ready {
                ready = nil
                lock.unlock()
                boot.resume(returning: value)
            } else if let id = value["id"] as? String, let call = pending, call.0 == id {
                pending = nil
                lock.unlock()
                if value["ok"] as? Bool == true { call.1.resume(returning: value) }
                else { call.1.resume(throwing: LabFailure(message: value["error"] as? String ?? "The guest rejected the request.")) }
            } else { lock.unlock() }
        }
    }

    private func fail(_ message: String) {
        lock.lock()
        stopping = true
        let boot = ready
        let call = pending?.1
        ready = nil
        pending = nil
        lock.unlock()
        boot?.resume(throwing: LabFailure(message: message))
        call?.resume(throwing: LabFailure(message: message))
        tinyarm_request_stop()
    }

    private func end(status: Int32, message: String) {
        lock.lock()
        running = false
        let boot = ready
        let call = pending?.1
        let completion = finished
        ready = nil
        pending = nil
        finished = nil
        lock.unlock()
        boot?.resume(throwing: LabFailure(message: message))
        call?.resume(throwing: LabFailure(message: message))
        completion?.resume()
    }
}
