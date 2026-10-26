import Foundation
import Testing

private actor ThemeServer: HabibiSyncHTTP {
    var malformed = false
    var requests = 0
    func fail() { malformed = true }
    func count() -> Int { requests }
    func send(_ request: URLRequest, limit: Int) async throws -> (Data, HTTPURLResponse) {
        #expect(request.url?.absoluteString == "https://themes.example/assets/themes.json")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.httpBody == nil)
        #expect(limit == 128 * 1024)
        requests += 1
        let bundle = Bundle(for: HabibiResourceBundle.self)
        let data = malformed ? Data("{\"version\":99}".utf8) : try Data(contentsOf: bundle.url(forResource: "themes", withExtension: "json")!)
        return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: [:])!)
    }
}

@Test @MainActor func publicThemesRefreshWithoutCredentialsAndMalformedResponsesPreserveTheCatalog() async throws {
    let server = ThemeServer()
    let appearance = HabibiAppearance(origin: try HabibiSyncOrigin("https://themes.example"), http: server, cacheDirectory: nil)
    await appearance.refresh()
    #expect(appearance.error == nil)
    let selected = appearance.catalog.theme("clay")
    #expect(selected.id == "clay")
    #expect(selected.colors.light["primary"] != selected.colors.dark["primary"])
    await server.fail()
    await appearance.refresh()
    #expect(appearance.error != nil)
    #expect(appearance.catalog.theme("clay").colors.light == selected.colors.light)
    #expect(appearance.catalog.theme("removed-theme").id == appearance.catalog.defaultTheme)
    #expect(await server.count() == 2)
}

@Test @MainActor func appearanceSurvivesEncryptedRestartAndFailedWritesDoNotChangeThePreference() async throws {
    let storage = MemoryPersistence()
    let store = HabibiStore(persistence: storage)
    let session = HabibiSession(store: store)
    #expect(await session.create(HabibiProfile(name: "Noor", goals: ["health"], style: "warm")))
    var profile = session.snapshot!.profile
    #expect(profile.theme == nil && profile.appearance == nil)
    profile.theme = "lavender"
    profile.appearance = "dark"
    let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(profile))
    _ = try await session.persist("profile", arguments: ["profile": encoded])
    #expect(session.snapshot?.profile == profile)
    #expect(try await HabibiStore(persistence: storage).restore()?.profile == profile)
    #expect(!String(decoding: storage.document!, as: UTF8.self).contains("lavender"))
    storage.rejectWrites = true
    var changed = profile
    changed.theme = "clay"
    await #expect(throws: (any Error).self) {
        _ = try await session.persist("profile", arguments: ["profile": JSONSerialization.jsonObject(with: JSONEncoder().encode(changed))])
    }
    #expect(session.snapshot?.profile == profile)
}
