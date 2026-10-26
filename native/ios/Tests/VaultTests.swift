import Foundation
import Testing

final class MemoryPersistence: HabibiPersistence, @unchecked Sendable {
    var identity: Data?
    var document: Data?
    var rejectWrites = false
    func loadIdentity() throws -> Data? { identity }
    func saveIdentity(_ data: Data) throws { identity = data }
    func deleteIdentity() throws { identity = nil }
    func loadDocument() throws -> Data? { document }
    func saveDocument(_ data: Data) throws {
        if rejectWrites { throw HabibiFailure(message: "Disk full") }
        document = data
    }
}

@Test func encryptedProfileSurvivesRestorationAndFailedSave() async throws {
    let storage = MemoryPersistence()
    let store = HabibiStore(persistence: storage)
    let profile = HabibiProfile(name: "Noor", goals: ["health", "planning"], style: "warm")
    let created = try await store.create(profile: profile)
    #expect(created.profile == profile)
    #expect(!String(decoding: storage.document!, as: UTF8.self).contains("Noor"))
    let restored = HabibiStore(persistence: storage)
    #expect(try await restored.restore()?.profile == profile)
    let previousDocument = storage.document
    storage.rejectWrites = true
    await #expect(throws: (any Error).self) {
        _ = try await restored.call("profile", arguments: ["profile": ["name": "Changed", "goals": ["learning"], "style": "direct"]], persist: true)
    }
    #expect(storage.document == previousDocument)
    #expect(try await restored.restore()?.profile == profile)
}

@Test func failedVaultCreationRollsBackNewKeyAndNeverOverwritesExistingData() async throws {
    let storage = MemoryPersistence()
    storage.rejectWrites = true
    let store = HabibiStore(persistence: storage)
    let profile = HabibiProfile(name: "Noor", goals: ["health"], style: "warm")
    await #expect(throws: (any Error).self) { _ = try await store.create(profile: profile) }
    #expect(storage.identity == nil)
    #expect(storage.document == nil)
    storage.rejectWrites = false
    _ = try await store.create(profile: profile)
    let original = storage.identity
    await #expect(throws: (any Error).self) { _ = try await store.create(profile: profile) }
    #expect(storage.identity == original)
}

@Test func authenticatedBackupRepairsInterruptedSetupWithoutDestroyingTheOldKeyOnFailure() async throws {
    let source = HabibiStore(persistence: MemoryPersistence())
    let profile = HabibiProfile(name: "Noor", goals: ["health"], style: "warm")
    _ = try await source.create(profile: profile)
    let recovery = try await source.call("export_recovery")
    let backup = try JSONSerialization.data(withJSONObject: recovery["backup"]!)
    let key = recovery["recoveryKey"] as! String
    let orphan = MemoryPersistence()
    let interrupted = try HabibiCore.execute(["operation": "create", "profile": ["name": "Old setup", "goals": ["planning"], "style": "direct"]])
    orphan.identity = try JSONSerialization.data(withJSONObject: interrupted["identity"]!)
    let oldKey = orphan.identity
    let store = HabibiStore(persistence: orphan)
    await #expect(throws: (any Error).self) { _ = try await store.restore() }
    #expect(try await store.incompleteSetup())
    await #expect(throws: (any Error).self) { _ = try await store.recover(backup: backup, key: "wrong") }
    #expect(orphan.identity == oldKey)
    orphan.rejectWrites = true
    await #expect(throws: (any Error).self) { _ = try await store.recover(backup: backup, key: key) }
    #expect(orphan.identity == oldKey)
    #expect(orphan.document == nil)
    orphan.rejectWrites = false
    #expect(try await store.recover(backup: backup, key: key).profile == profile)
    #expect(try await HabibiStore(persistence: orphan).restore()?.profile == profile)
    await #expect(throws: (any Error).self) { try await store.discardIncompleteSetup() }
}
