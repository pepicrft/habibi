package fyi.habibi.app

import android.content.Intent
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class HabibiSessionTest {
    @Test fun bridgeAndStorageRunInOrderOnOneBackgroundThread() {
        val worker = Executors.newSingleThreadExecutor()
        try {
            val main = Thread.currentThread(); val threads = mutableListOf<Thread>(); val core = FixtureCore(); val memory = MemoryVault()
            val storage = object : VaultStorage {
                override fun load(): JSONObject? { threads.add(Thread.currentThread()); return memory.load() }
                override fun save(record: JSONObject) { threads.add(Thread.currentThread()); memory.save(record) }
            }
            val session = HabibiSession(storage, { threads.add(Thread.currentThread()); core.execute(it) }, worker, { it() })
            session.start(); session.create(profile()); session.updateProfile(profile("Changed"))
            worker.submit {}.get(5, TimeUnit.SECONDS)
            assertEquals(1, threads.toSet().size); assertNotEquals(main, threads.first())
            assertEquals(listOf("create", "profile"), core.calls.map { it.getString("operation") })
            assertEquals("Changed", session.state!!.getJSONObject("profile").getString("name"))
        } finally { worker.shutdownNow() }
    }
    @Test fun identityAndDocumentAreSavedBeforeSignedInStateIsPublished() {
        val store = MemoryVault(); val core = FixtureCore(); val session = fixtureSession(store, core)
        session.start()
        store.beforeSave = { assertNull(session.state) }
        session.create(profile())
        assertNotNull(session.state)
        assertEquals("Alex", session.state!!.getJSONObject("profile").getString("name"))
        val saved = JSONObject(store.durable!!)
        assertTrue(saved.has("identity")); assertTrue(saved.has("document")); assertFalse(saved.has("state"))
        val restarted = fixtureSession(store, core); restarted.start()
        assertEquals(session.state.toString(), restarted.state.toString())
    }
    @Test fun failedInitialSaveDoesNotSignInAndCanBeRetried() {
        val store = MemoryVault(); val session = fixtureSession(store, FixtureCore())
        session.start(); store.failSave = true; session.create(profile())
        assertNull(session.state); assertNull(store.durable); assertEquals("Disk full", session.error)
        store.failSave = false; session.create(profile()); assertNotNull(session.state)
    }
    @Test fun failedProfileAndRecoveryPreservePriorDurableVaultAndPublishedState() {
        val store = MemoryVault(); val core = FixtureCore(); val session = fixtureSession(store, core)
        session.start(); session.create(profile())
        val state = session.state.toString(); val durable = store.durable
        store.beforeSave = { assertEquals(state, session.state.toString()) }
        store.failSave = true
        session.updateProfile(profile("Other")); assertEquals(state, session.state.toString()); assertEquals(durable, store.durable)
        session.recover(JSONObject(), "key"); assertEquals(state, session.state.toString()); assertEquals(durable, store.durable)
        store.failSave = false
        val restarted = fixtureSession(store, core); restarted.start(); assertEquals(state, restarted.state.toString())
    }
    @Test fun loadErrorsNeverResetStorageOrEnableCreate() {
        val store = MemoryVault().apply { durable = "unreadable"; failLoad = true }
        val core = FixtureCore(); val session = fixtureSession(store, core)
        session.start(); session.create(profile())
        assertTrue(session.loadFailed); assertNull(session.state); assertEquals("unreadable", store.durable)
        assertTrue(core.calls.isEmpty()); assertEquals(0, store.saves)
    }
    @Test fun nativeFailureDoesNotChangePublishedOrDurableState() {
        val store = MemoryVault(); val core = FixtureCore(); val session = fixtureSession(store, core)
        session.start(); session.create(profile()); val previous = store.durable
        core.failOperation = "profile"; session.updateProfile(profile("Other"))
        assertEquals(previous, store.durable); assertEquals("Alex", session.state!!.getJSONObject("profile").getString("name"))
        assertEquals("Fixture rejected operation", session.error)
    }
    @Test fun reviewDenialDoesNotCommitAndStaleApprovalIsRejected() {
        val store = MemoryVault(); val core = FixtureCore(); val session = fixtureSession(store, core)
        session.start(); session.create(profile())
        val args = JSONObject().put("definition", definition())
        session.tool("save_kit", args); session.decide(session.review!!.ticket, false)
        assertFalse(core.calls.any { it.getString("operation") == "commit_kit" })
        session.tool("save_kit", args); val ticket = session.review!!.ticket
        session.updateProfile(profile("Changed")); session.decide(ticket, true)
        assertTrue(session.error!!.contains("changed during review")); assertNull(session.review)
        assertFalse(core.calls.any { it.getString("operation") == "commit_kit" })
        assertEquals(0, session.state!!.getJSONArray("kits").length())
    }
    @Test fun approvedKitRequiresSuccessfulStorageAndCannotBeCommittedTwice() {
        val store = MemoryVault(); val core = FixtureCore(); val session = fixtureSession(store, core)
        session.start(); session.create(profile()); val previous = store.durable
        val args = JSONObject().put("definition", definition())
        session.tool("save_kit", args)
        store.beforeSave = { if (store.saves == 1) assertEquals(0, session.state!!.getJSONArray("kits").length()) }
        store.failSave = true; session.decide(session.review!!.ticket, true)
        assertEquals(0, session.state!!.getJSONArray("kits").length()); assertEquals(previous, store.durable)
        store.failSave = false; session.tool("save_kit", args); val ticket = session.review!!.ticket
        session.decide(ticket, true); assertEquals(1, session.state!!.getJSONArray("kits").length())
        val commits = core.calls.count { it.getString("operation") == "commit_kit" }
        session.decide(ticket, true); assertEquals(commits, core.calls.count { it.getString("operation") == "commit_kit" })
    }
    @Test fun addEntryFailureDoesNotEraseEntriesOrCallSuccess() {
        val store = MemoryVault(); val core = FixtureCore(); val session = fixtureSession(store, core)
        session.start(); session.create(profile()); session.tool("save_kit", JSONObject().put("definition", definition())); session.decide(session.review!!.ticket, true)
        var successes = 0
        session.addEntry("energy-kit", JSONObject().put("energy", 7)) { successes++ }
        val previous = store.durable; store.failSave = true
        session.addEntry("energy-kit", JSONObject().put("energy", 3)) { successes++ }
        assertEquals(1, successes); assertEquals(previous, store.durable)
        assertEquals(1, session.state!!.getJSONArray("kits").getJSONObject(0).getJSONArray("entries").length())
    }
    @Test fun inferenceWaitsForNativeConsentAndDenialIsSentWithoutIdentity() {
        val store = MemoryVault(); val core = FixtureCore(); val transport = FixtureTransport(); val session = fixtureSession(store, core, transport)
        session.start(); session.create(profile()); session.configure(InferenceEndpoint("http://10.0.2.2:8083/inference", "test"))
        transport.replies.add(transport.reviewReply()); session.send("Design an energy kit")
        assertNotNull(session.review); assertTrue(session.chatting); assertEquals(1, transport.bodies.size)
        assertFalse(core.calls.any { it.getString("operation") == "commit_kit" })
        session.decide(session.review!!.ticket, false)
        assertFalse(session.chatting); assertEquals(2, transport.bodies.size)
        val input = transport.bodies.last().getJSONArray("input")
        val output = JSONObject(input.getJSONObject(input.length() - 1).getString("output"))
        assertFalse(output.getBoolean("approved")); assertFalse(output.getBoolean("changed"))
        assertFalse(transport.bodies.joinToString().contains("fixture-content-key"))
        assertFalse(transport.bodies.joinToString().contains("Alex"))
    }
    @Test fun stopRejectsPendingReviewAndKeepsCommittedVault() {
        val store = MemoryVault(); val core = FixtureCore(); val transport = FixtureTransport(); val session = fixtureSession(store, core, transport)
        session.start(); session.create(profile()); val profile = session.state!!.getJSONObject("profile").toString()
        session.configure(InferenceEndpoint("http://10.0.2.2:8083/inference", "test")); transport.replies.add(transport.reviewReply())
        session.send("Design a kit"); val ticket = session.review!!.ticket; session.stop(); session.decide(ticket, true)
        assertTrue(transport.cancelled); assertNull(session.review); assertFalse(session.chatting)
        assertEquals(profile, session.state!!.getJSONObject("profile").toString()); assertEquals(0, session.state!!.getJSONArray("kits").length())
        val restarted = fixtureSession(store, core); restarted.start()
        assertEquals(session.lines.map { it.text }, restarted.lines.map { it.text })
        assertFalse(core.calls.any { it.getString("operation") == "commit_kit" })
        session.send("Continue")
        assertTrue(transport.bodies.last().toString().contains("approved\\\":false"))
    }
    @Test fun failedCommitFinishesChatAndPreservesVault() {
        val store = MemoryVault(); val core = FixtureCore(); val transport = FixtureTransport(); val session = fixtureSession(store, core, transport)
        session.start(); session.create(profile())
        session.configure(InferenceEndpoint("http://10.0.2.2:8083/inference", "test")); transport.replies.add(transport.reviewReply())
        session.send("Design a kit"); val durable = store.durable
        store.failSave = true; session.decide(session.review!!.ticket, true)
        assertFalse(session.chatting); assertNull(session.review); assertEquals(durable, store.durable)
    }
    @Test fun disconnectedChatNeverPretendsToReplyOrSendsNetworkTraffic() {
        val store = MemoryVault(); val transport = FixtureTransport(); val session = fixtureSession(store, FixtureCore(), transport)
        session.start(); session.create(profile()); session.send("Hello")
        assertTrue(transport.bodies.isEmpty()); assertTrue(session.lines.isEmpty()); assertTrue(session.error!!.startsWith("Not connected"))
    }
    @Test fun localValidationFailureReturnsToAgentAndOnlyArchivesTheTranscript() {
        val store = MemoryVault(); val core = FixtureCore(); val transport = FixtureTransport(); val session = fixtureSession(store, core, transport)
        session.start(); session.create(profile()); val previousProfile = session.state!!.getJSONObject("profile").toString()
        session.configure(InferenceEndpoint("http://10.0.2.2:8083/inference", "test"))
        core.failOperation = "kit_tool"; transport.replies.add(transport.reviewReply()); session.send("Design a kit")
        assertEquals(2, transport.bodies.size); assertFalse(session.chatting); assertNull(session.review)
        val history = transport.bodies.last().getJSONArray("input")
        assertEquals("Fixture rejected operation", JSONObject(history.getJSONObject(history.length() - 1).getString("output")).getString("error"))
        assertEquals(previousProfile, session.state!!.getJSONObject("profile").toString()); assertEquals(0, session.state!!.getJSONArray("kits").length())
        assertEquals("Ready.", session.lines.last().text)
        val restarted = fixtureSession(store, core); restarted.start()
        assertEquals(session.lines.map { it.text }, restarted.lines.map { it.text })
    }
    @Test fun inferenceStopsAfterEightRequestsEvenWhenToolsKeepReturning() {
        val store = MemoryVault(); val transport = FixtureTransport(); val session = fixtureSession(store, FixtureCore(), transport)
        session.start(); session.create(profile()); session.configure(InferenceEndpoint("http://10.0.2.2:8083/inference", "test"))
        repeat(10) { index -> transport.replies.add(JSONObject().put("output", JSONArray())
            .put("tool", JSONObject().put("callId", "call-$index").put("name", "list_kits").put("arguments", JSONObject()))) }
        session.send("List my kits")
        assertEquals(8, transport.bodies.size); assertFalse(session.chatting)
        assertTrue(session.error!!.contains("eight requests"))
    }
    @Test fun debugEndpointAcceptsOnlyLoopbackAndRejectsRedirectStyleUrls() {
        fun intent(url: String) = Intent().putExtra("inference_url", url).putExtra("inference_token", "test")
        val accepted = intent("http://10.0.2.2:8083/inference")
        if (BuildConfig.DEBUG) assertNotNull(InferenceEndpoint.fromDebugIntent(accepted))
        else assertNull(InferenceEndpoint.fromDebugIntent(accepted))
        assertFalse(accepted.hasExtra("inference_url")); assertFalse(accepted.hasExtra("inference_token"))
        for (url in listOf("http://example.com/inference", "https://10.0.2.2/inference", "http://localhost@example.com/inference", "http://10.0.2.2/inference#other")) {
            assertNull(InferenceEndpoint.fromDebugIntent(intent(url)))
        }
    }
}
