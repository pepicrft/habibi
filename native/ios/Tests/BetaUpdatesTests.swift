import Foundation
import Testing

private actor BetaUpdateServer: HabibiSyncHTTP {
    var response = "{\"builds\":[]}"
    var status = 200
    var requests = 0

    func respond(_ builds: [[String: String]], status: Int = 200) throws {
        response = String(decoding: try JSONSerialization.data(withJSONObject: ["builds": builds]), as: UTF8.self)
        self.status = status
    }

    func count() -> Int { requests }

    func send(_ request: URLRequest, limit: Int) async throws -> (Data, HTTPURLResponse) {
        #expect(request.url?.absoluteString == "https://beta.example/v1/updates/ios")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
        #expect(request.httpBody == nil)
        requests += 1
        return (Data(response.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: [:])!)
    }
}

@Test @MainActor func betaUpdatesChooseTheNewestCompatibleVersionThenBuildAndNeverOfferDowngrades() async throws {
    let server = BetaUpdateServer()
    let updates = HabibiBetaUpdates(origin: try HabibiSyncOrigin("https://beta.example"), http: server,
        installed: .init(version: "0.2.9", build: "9.2", minimumOSVersion: "17.0"), systemVersion: "26.5", enabled: true)
    func build(_ version: String, _ number: String, _ os: String = "17.0") -> [String: String] {
        ["version": version, "build": number, "minimumOSVersion": os]
    }
    try await server.respond([
        build("0.2.9", "9.10"), build("0.3.0", "1", "27.0"),
        build("0.2.10", "1.0", "26.5.0"), build("0.2.8", "999"), build("0.2.10", "1.2")
    ])
    await updates.refresh()
    #expect(updates.available?.label == "0.2.10 (1.2)")
    #expect(updates.checked && updates.error == nil)
    await updates.refresh()
    #expect(await server.count() == 1)

    try await server.respond([build("0.2.9", "9.10"), build("0.2.8", "999")])
    await updates.refresh(force: true)
    #expect(updates.available?.label == "0.2.9 (9.10)")

    try await server.respond([build("0.2.9", "9.2.0"), build("0.2.8", "999")])
    await updates.refresh(force: true)
    #expect(updates.available == nil && updates.checked)

    try await server.respond([build("0.2.10", "1")])
    await updates.refresh(force: true)
    #expect(updates.available != nil)
    try await server.respond([], status: 503)
    await updates.refresh(force: true)
    #expect(updates.available == nil && !updates.checked && updates.error != nil)

    try await server.respond([build("0.2.11", "bad")])
    await updates.refresh(force: true)
    #expect(updates.available == nil && !updates.checked && updates.error != nil)
    try await server.respond([])
    await updates.refresh(force: true)
    #expect(updates.available == nil && updates.checked && updates.error == nil)

    let disabled = HabibiBetaUpdates(origin: try HabibiSyncOrigin("https://beta.example"), http: server, enabled: false)
    let count = await server.count()
    await disabled.refresh(force: true)
    #expect(await server.count() == count)
    #expect(disabled.available == nil && !disabled.checked)
}
