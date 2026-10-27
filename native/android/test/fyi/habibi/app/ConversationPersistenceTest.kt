package fyi.habibi.app

import android.os.Looper
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import java.time.Duration
import java.time.Instant
import java.util.UUID
import java.util.concurrent.Executor

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class ConversationPersistenceTest {
    private val endpoint = InferenceEndpoint("http://10.0.2.2:8083/inference", "ephemeral-token")
    private fun HabibiSession.archive() = state!!.getJSONArray("conversations")
    private fun FixtureCore.operations() = calls.map { it.getString("operation") }
    private fun advance(milliseconds: Long = 500) = shadowOf(Looper.getMainLooper()).idleFor(Duration.ofMillis(milliseconds))

    @Test fun agentReactionEndsTurnReplacesInPlaceAndSurvivesRelaunch() {
        val store = MemoryVault(); val core = FixtureCore(); val transport = FixtureTransport()
        val session = fixtureSession(store, core, transport)
        session.start(); session.create(profile()); session.configure(endpoint); session.send("Let's make a plan")
        val target = session.lines.first()
        val original = session.lines
        for (emoji in listOf("👍", "❤️")) {
            val before = transport.bodies.size
            transport.replies.add(JSONObject().put("tool", JSONObject().put("name", "react_to_message").put("callId", "reaction-$before")
                .put("arguments", JSONObject().put("message_id", target.id).put("emoji", emoji))))
            session.send("Thanks, that's all")
            assertEquals(before + 1, transport.bodies.size)
            assertFalse(session.chatting); assertNull(session.review); assertNull(session.error)
            assertEquals(emoji, session.lines.first().reaction)
            assertEquals(target.id, session.lines.first().id); assertEquals(target.createdAt, session.lines.first().createdAt)
            assertEquals(original.count { it.role == "Habibi" }, session.lines.count { it.role == "Habibi" })
            assertFalse(session.lines.any { it.role == "Kit tool" })
        }
        val restoredCore = FixtureCore(); val restarted = fixtureSession(store, restoredCore)
        restarted.start(); assertEquals(session.lines, restarted.lines)
        restarted.configure(endpoint); restarted.send("Continue")
        val request = restoredCore.calls.last { it.getString("operation") == "agent_request" }
        val targets = request.getJSONArray("reactionTargets")
        assertEquals("❤️", targets.getJSONObject(0).getString("reaction"))
        assertEquals(target.id, targets.getJSONObject(0).getString("messageId"))
        assertFalse(request.getJSONArray("history").toString().contains("function_call"))
    }

    @Test fun agentCannotReactToOtherConversationsOrAssistantMessages() {
        val store = MemoryVault(); val core = FixtureCore(); val transport = FixtureTransport()
        val session = fixtureSession(store, core, transport)
        session.start(); session.create(profile()); session.configure(endpoint); session.send("First thread")
        val foreign = session.lines.first().id
        session.newConversation(); session.send("Second thread")
        val assistant = session.lines.last().id
        for (id in listOf(foreign, assistant, UUID.randomUUID().toString())) {
            transport.replies.add(JSONObject().put("tool", JSONObject().put("name", "react_to_message").put("callId", "invalid")
                .put("arguments", JSONObject().put("message_id", id).put("emoji", "👍"))))
            session.send("Acknowledge this")
            assertTrue(session.conversations.flatMap { it.lines }.none { it.reaction != null })
            assertFalse(session.chatting); assertNull(session.review)
        }
    }

    @Test fun relaunchRestoresIndependentUnicodeDraftsCardsDefinitionsIdsAndTimes() {
        val store = MemoryVault(); val core = FixtureCore(); val transport = FixtureTransport()
        val session = fixtureSession(store, core, transport)
        session.start(); session.create(profile()); session.configure(endpoint); session.inferenceConsent = true
        val first = session.conversation.id
        transport.replies.add(componentReply()); session.send("أفكار أولى 🌙")
        session.tool("write_kit", JSONObject().put("definition", definition().put("name", "طاقة 🌱")))
        session.conversationDraft = "مسودة أولى 👩🏽‍💻\n未送信"
        session.conversation.selectionStart = 3; session.conversation.scrollY = 42
        assertTrue(session.newConversation()); val second = session.conversation.id
        val card = resultCard().put("fallback", "Deuxième carte 🪷")
        transport.replies.add(componentReply(card)); session.send("Deuxième idée 🪷")
        session.tool("write_kit", JSONObject().put("definition", definition().put("name", "Deuxième kit")))
        session.conversationDraft = "Brouillon indépendant 🧑🏾‍🚀\nनमस्ते"
        session.flushConversations()
        val archive = session.archive().toString()
        assertFalse(archive.contains("ephemeral-token")); assertFalse(archive.contains("history"))
        assertFalse(archive.contains("function_call")); assertFalse(archive.contains("consent"))
        assertFalse(archive.contains("selectionStart")); assertFalse(archive.contains("scrollY"))
        for (chat in session.conversations) {
            assertEquals(chat.id, UUID.fromString(chat.id).toString()); Instant.parse(chat.createdAt)
            chat.lines.forEach { assertEquals(it.id, UUID.fromString(it.id).toString()); Instant.parse(it.createdAt) }
        }
        val freshCore = FixtureCore(); val freshTransport = FixtureTransport()
        val restarted = fixtureSession(store, freshCore, freshTransport); restarted.start()
        assertEquals(listOf("restore"), freshCore.operations()); assertTrue(freshTransport.bodies.isEmpty())
        assertFalse(restarted.connected); assertFalse(restarted.inferenceConsent); assertFalse(restarted.chatting); assertNull(restarted.review)
        assertEquals(listOf(first, second), restarted.conversations.map { it.id })
        assertEquals(archive, restarted.archive().toString())
        session.conversations.zip(restarted.conversations).forEach { (before, after) ->
            assertEquals(before.createdAt, after.createdAt); assertEquals(before.lines, after.lines)
            assertEquals(before.draft, after.draft); assertEquals(before.definition.toString(), after.definition.toString())
            assertEquals(before.toolResult, after.toolResult); assertEquals(0, after.selectionStart); assertEquals(0, after.scrollY)
        }
        var disclosures = 0
        val restoredCard = restarted.lines.single { it.component != null }
        restarted.componentSource(first, restoredCard.id, "show_source") { disclosures++ }
        assertEquals(1, disclosures); assertTrue(freshTransport.bodies.isEmpty())
        assertTrue(restarted.selectConversation(second)); assertEquals("Brouillon indépendant 🧑🏾‍🚀\nनमस्ते", restarted.conversationDraft)
        restarted.configure(endpoint); restarted.send("Continue only this conversation")
        val input = freshTransport.bodies.single().getJSONArray("input")
        val wire = input.toString()
        assertTrue(wire.contains("Deuxième idée")); assertTrue(wire.contains("Deuxième carte"))
        assertFalse(wire.contains("أفكار")); assertFalse(wire.contains("Synthetic energy"))
        assertFalse(wire.contains("Brouillon")); assertFalse(wire.contains("Deuxième kit")); assertFalse(wire.contains("metrics"))
        for (index in 0 until input.length()) assertEquals(setOf("role", "content"), input.getJSONObject(index).keys().asSequence().toSet())
    }

    @Test fun relaunchNeverRestoresPendingReviewsToolRequestsOrInferenceConfiguration() {
        val store = MemoryVault(); val core = FixtureCore(); val transport = FixtureTransport()
        val session = fixtureSession(store, core, transport)
        session.start(); session.create(profile()); session.configure(endpoint); session.inferenceConsent = true
        transport.replies.add(componentReply()); session.send("Show a result")
        transport.replies.add(transport.reviewReply()); session.send("Propose a Kit")
        assertNotNull(session.review); assertTrue(session.chatting)
        val freshCore = FixtureCore(); val freshTransport = FixtureTransport()
        val restarted = fixtureSession(store, freshCore, freshTransport); restarted.start()
        assertNull(restarted.review); assertFalse(restarted.chatting); assertFalse(restarted.busy)
        assertFalse(restarted.connected); assertFalse(restarted.inferenceConsent)
        assertEquals(listOf("restore"), freshCore.operations()); assertTrue(freshTransport.bodies.isEmpty())
        val archive = restarted.archive().toString()
        assertFalse(archive.contains("approvalRequired")); assertFalse(archive.contains("function_call")); assertFalse(archive.contains("call_id"))
        restarted.configure(endpoint); restarted.send("Continue")
        val input = freshTransport.bodies.single().getJSONArray("input")
        assertEquals(listOf("user", "assistant", "assistant", "user", "user"),
            (0 until input.length()).map { input.getJSONObject(it).getString("role") })
        assertFalse(input.toString().contains("function_call")); assertFalse(input.toString().contains("approved"))
        assertFalse(freshCore.operations().any { it == "kit_tool" || it == "commit_kit" })
    }

    @Test fun draftDebounceFailureKeepsPublishedAndDurableStateAndRetriesWithoutSpinning() {
        val store = MemoryVault(); val core = FixtureCore(); val session = fixtureSession(store, core)
        session.start(); session.create(profile())
        val durable = store.durable; val state = session.state.toString()
        store.beforeSave = { assertEquals(state, session.state.toString()); assertEquals(durable, store.durable) }
        store.failSave = true
        session.conversationDraft = "First edit"; advance(300); session.conversationDraft = "Keep this unsaved 🌱"
        advance(499); assertEquals(1, store.saves)
        advance(1)
        assertEquals(durable, store.durable); assertEquals(state, session.state.toString())
        assertEquals("Keep this unsaved 🌱", session.conversationDraft); assertTrue(session.error!!.contains("not saved"))
        assertEquals(1, core.operations().count { it == "save_conversations" })
        advance(10_000); assertEquals(1, core.operations().count { it == "save_conversations" })
        val beforeRetry = fixtureSession(store, FixtureCore()); beforeRetry.start(); assertEquals("", beforeRetry.conversationDraft)
        store.failSave = false; session.flushConversations()
        assertNull(session.error); assertEquals(2, store.saves)
        store.beforeSave = {}
        val restarted = fixtureSession(store, FixtureCore()); restarted.start(); assertEquals("Keep this unsaved 🌱", restarted.conversationDraft)
        core.failOperation = "save_conversations"; session.conversationDraft = "Native rejection stays retryable"; session.flushConversations()
        assertTrue(session.error!!.contains("Fixture rejected operation")); assertEquals("Keep this unsaved 🌱", session.archive().getJSONObject(0).getString("composer"))
        core.failOperation = null; session.flushConversations()
        assertNull(session.error); assertEquals("Native rejection stays retryable", session.archive().getJSONObject(0).getString("composer"))
    }

    @Test fun editsDuringSerializedStorageWriteAreSavedByTheNextDebounceNotOverwrittenOrLooped() {
        val queue = ArrayDeque<Runnable>(); val store = MemoryVault(); val core = FixtureCore()
        val session = HabibiSession(store, core::execute, Executor { queue.add(it) }, { it() }, FixtureTransport())
        session.start(); queue.removeFirst().run(); session.create(profile()); queue.removeFirst().run()
        session.conversationDraft = "Snapshot"; session.flushConversations()
        store.beforeSave = { session.conversationDraft = "Typed during disk write 🖋️" }
        assertTrue(session.busy); assertFalse(session.newConversation()); queue.removeFirst().run()
        assertEquals("Typed during disk write 🖋️", session.conversationDraft)
        assertEquals("Snapshot", session.archive().getJSONObject(0).getString("composer"))
        assertTrue(queue.isEmpty()); advance(); assertEquals(1, queue.size); queue.removeFirst().run()
        assertEquals("Typed during disk write 🖋️", session.archive().getJSONObject(0).getString("composer"))
        assertEquals(3, store.saves); advance(10_000); assertTrue(queue.isEmpty()); assertFalse(session.busy)
    }

    @Test fun autosavesDoNotInvalidateTheirOwnReviewAndFlushAfterApprovalOrDenial() {
        val store = MemoryVault(); val core = FixtureCore(); val session = fixtureSession(store, core)
        session.start(); session.create(profile()); session.conversationDraft = "Before review"
        session.tool("save_kit", JSONObject().put("definition", definition()))
        assertEquals(listOf("create", "save_conversations", "kit_tool"), core.operations())
        val ticket = session.review!!.ticket; val durable = store.durable
        session.conversationDraft = "Edited during review"; advance(); session.flushConversations()
        assertEquals(durable, store.durable); assertEquals(ticket, session.review!!.ticket)
        session.decide(ticket, true)
        assertNull(session.error); assertNull(session.review); assertEquals(1, session.state!!.getJSONArray("kits").length())
        assertEquals(listOf("commit_kit", "save_conversations"), core.operations().takeLast(2))
        assertEquals("Edited during review", session.archive().getJSONObject(0).getString("composer"))
        session.tool("update_kit", JSONObject().put("id", "energy-kit").put("definition", definition()))
        session.conversationDraft = "Declined but retain draft"; advance()
        session.decide(session.review!!.ticket, false)
        assertEquals("save_conversations", core.operations().last()); assertEquals(1, core.operations().count { it == "commit_kit" })
        val restarted = fixtureSession(store, core); restarted.start()
        assertEquals("Declined but retain draft", restarted.conversationDraft); assertNull(restarted.review)
    }

    @Test fun sendReplyAndStopCheckpointWithoutWaitingForDebounce() {
        val store = MemoryVault(); val core = FixtureCore(); val session = fixtureSession(store, core)
        session.start(); session.create(profile()); session.configure(endpoint)
        session.conversationDraft = "Send this"; session.send("Send this")
        val operations = core.operations()
        assertTrue(operations.indexOf("save_conversations") < operations.indexOf("agent_request"))
        assertEquals("", session.archive().getJSONObject(0).getString("composer"))
        val restarted = fixtureSession(store, core); restarted.start()
        assertEquals(listOf("Send this", "Ready."), restarted.lines.map { it.text })
        session.stop()
        val stopped = fixtureSession(store, core); stopped.start()
        assertEquals(session.lines.map { it.text }, stopped.lines.map { it.text })
    }

    @Test fun queuedAutosaveDefersWhenAnInFlightReplyCreatesAReview() {
        val queue = ArrayDeque<Runnable>(); val store = MemoryVault(); val core = FixtureCore(); val transport = FixtureTransport()
        val session = HabibiSession(store, core::execute, Executor { queue.add(it) }, { it() }, transport)
        session.start(); queue.removeFirst().run(); session.create(profile()); queue.removeFirst().run()
        session.configure(endpoint); queue.removeFirst().run(); transport.replies.add(transport.reviewReply())
        session.send("Design a kit"); session.conversationDraft = "Typed while queued"; session.flushConversations()
        assertEquals(2, queue.size); queue.removeFirst().run()
        val ticket = session.review!!.ticket; val durable = store.durable
        queue.removeFirst().run(); assertEquals(durable, store.durable)
        session.conversationDraft = "Edited while reviewing"; advance(); assertTrue(queue.isEmpty())
        session.decide(ticket, true); queue.removeFirst().run()
        assertNull(session.error); assertNull(session.review); assertFalse(session.busy); assertFalse(session.chatting)
        assertEquals(1, session.state!!.getJSONArray("kits").length())
        val restarted = fixtureSession(store, core); restarted.start()
        assertEquals("Edited while reviewing", restarted.conversationDraft)
    }

    @Test fun archiveFailureAfterApprovalDoesNotUndoCommittedKitAndCanRetryDeferredDraft() {
        val store = MemoryVault(); val core = FixtureCore(); val session = fixtureSession(store, core)
        session.start(); session.create(profile()); session.tool("save_kit", JSONObject().put("definition", definition()))
        session.conversationDraft = "Keep this even if the archive write fails"
        var writes = 0
        store.beforeSave = { if (++writes == 2) store.failSave = true }
        session.decide(session.review!!.ticket, true)
        assertNull(session.review); assertEquals(1, session.state!!.getJSONArray("kits").length())
        assertTrue(session.error!!.contains("not saved")); assertEquals(2, store.saves)
        val beforeRetry = fixtureSession(store, core); beforeRetry.start()
        assertEquals(1, beforeRetry.state!!.getJSONArray("kits").length()); assertEquals("", beforeRetry.conversationDraft)
        store.beforeSave = {}; store.failSave = false; session.flushConversations()
        assertNull(session.error)
        val restarted = fixtureSession(store, core); restarted.start()
        assertEquals(1, restarted.state!!.getJSONArray("kits").length())
        assertEquals("Keep this even if the archive write fails", restarted.conversationDraft)
        assertEquals(1, core.operations().count { it == "commit_kit" })
    }

    @Test fun recoveryReplacesOldOwnersDirtyConversationsAndLegacyBackupsRemainUsable() {
        val sourceStore = MemoryVault(); val sourceCore = FixtureCore(); val source = fixtureSession(sourceStore, sourceCore)
        source.start(); source.create(profile("Recovered owner")); source.conversationDraft = "Recovered owner's draft 🐪"; source.flushConversations()
        val store = MemoryVault(); val core = FixtureCore(); val session = fixtureSession(store, core)
        session.start(); session.create(profile("Old owner")); session.conversationDraft = "Old owner's saved draft"; session.flushConversations()
        session.conversationDraft = "Old owner's unsaved edit"; session.inferenceConsent = true
        core.recoveredState = source.state
        store.failSave = true; session.recover(JSONObject(), "key")
        assertEquals("Old owner's unsaved edit", session.conversationDraft)
        store.failSave = false; session.recover(JSONObject(), "key")
        assertEquals("Recovered owner's draft 🐪", session.conversationDraft)
        assertEquals(source.conversation.id, session.conversation.id); assertFalse(session.inferenceConsent)
        val saves = store.saves; advance(10_000); assertEquals(saves, store.saves)
        val restarted = fixtureSession(store, core); restarted.start()
        assertEquals("Recovered owner's draft 🐪", restarted.conversationDraft)
        assertFalse(restarted.archive().toString().contains("Old owner"))
        core.recoveredState = null; session.recover(JSONObject(), "legacy-key")
        assertEquals("", session.conversationDraft); assertTrue(session.lines.isEmpty()); assertNull(session.draft)
        val legacy = fixtureSession(store, core); legacy.start()
        assertEquals(1, legacy.conversations.size); legacy.conversationDraft = "First new draft"; legacy.flushConversations()
        assertEquals("First new draft", legacy.archive().getJSONObject(0).getString("composer"))
    }
}
